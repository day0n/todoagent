use std::path::Path;
use std::time::Duration;

use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};
use thiserror::Error;
use uuid::Uuid;

use crate::models::{
    Bootstrap, List, MessageRole, QueuedTurn, Runtime, RuntimeKind, SessionBundle, SessionMessage,
    SessionState, SessionTurn, Task, TaskSession, TaskStatus, TurnStatus,
};

const SCHEMA_VERSION: i64 = 2;
const SCHEMA_CHECKSUM: &str = "todoagent-native-v2-session-model";

#[derive(Debug, Error)]
pub enum StoreError {
    #[error(transparent)]
    Sql(#[from] rusqlite::Error),
    #[error("record not found")]
    NotFound,
    #[error("{0}")]
    Conflict(&'static str),
    #[error("{0}")]
    Invalid(String),
}

pub type StoreResult<T> = Result<T, StoreError>;

pub struct Store {
    connection: Connection,
}

impl Store {
    pub fn open(path: &Path) -> StoreResult<Self> {
        let connection = Connection::open(path)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.pragma_update(None, "synchronous", "NORMAL")?;
        migrate(&connection)?;
        let store = Self { connection };
        store.reconcile_interrupted_turns()?;
        Ok(store)
    }

    pub fn health(&self) -> StoreResult<Value> {
        let version: i64 =
            self.connection
                .query_row("SELECT max(version) FROM schema_migration", [], |row| {
                    row.get(0)
                })?;
        Ok(json!({ "ok": true, "schemaVersion": version }))
    }

    pub fn bootstrap(&self) -> StoreResult<Bootstrap> {
        Ok(Bootstrap {
            revision: self.revision()?,
            lists: self.lists()?,
            tasks: self.tasks()?,
            runtimes: self.runtimes()?,
            sessions: self.sessions()?,
        })
    }

    pub fn revision(&self) -> StoreResult<i64> {
        Ok(self.connection.query_row(
            "SELECT revision FROM app_revision WHERE singleton=1",
            [],
            |row| row.get(0),
        )?)
    }

    pub fn create_list(
        &self,
        name: &str,
        color: &str,
        repository_path: Option<&str>,
    ) -> StoreResult<List> {
        let now = now();
        let list = List {
            id: Uuid::new_v4().to_string(),
            name: name.to_owned(),
            color: color.to_owned(),
            repository_path: repository_path.map(str::to_owned),
            archived_at: None,
            created_at: now.clone(),
            updated_at: now,
        };
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO list(id,name,color,repository_path,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6)",
            params![list.id, list.name, list.color, list.repository_path, list.created_at, list.updated_at],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(list)
    }

    pub fn create_task(
        &self,
        title: &str,
        note: &str,
        list_id: Option<&str>,
        due_date: Option<&str>,
    ) -> StoreResult<Task> {
        if let Some(id) = list_id {
            let exists: Option<i64> = self
                .connection
                .query_row(
                    "SELECT 1 FROM list WHERE id=?1 AND archived_at IS NULL",
                    [id],
                    |row| row.get(0),
                )
                .optional()?;
            if exists.is_none() {
                return Err(StoreError::NotFound);
            }
        }
        let timestamp = now();
        let task = Task {
            id: Uuid::new_v4().to_string(),
            list_id: list_id.map(str::to_owned),
            title: title.to_owned(),
            note: note.to_owned(),
            status: TaskStatus::Open,
            due_date: due_date.map(str::to_owned),
            completed_at: None,
            created_at: timestamp.clone(),
            updated_at: timestamp,
        };
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO task(id,list_id,title,note,status,due_date,created_at,updated_at) VALUES(?1,?2,?3,?4,'open',?5,?6,?7)",
            params![task.id, task.list_id, task.title, task.note, task.due_date, task.created_at, task.updated_at],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(task)
    }

    pub fn set_task_status(&self, id: &str, status: TaskStatus) -> StoreResult<Task> {
        let timestamp = now();
        let completed_at = (status == TaskStatus::Completed).then_some(timestamp.clone());
        let transaction = self.connection.unchecked_transaction()?;
        let changed = transaction.execute(
            "UPDATE task SET status=?1,completed_at=?2,updated_at=?3 WHERE id=?4",
            params![status.as_str(), completed_at, timestamp, id],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.task(id)?.ok_or(StoreError::NotFound)
    }

    pub fn task(&self, id: &str) -> StoreResult<Option<Task>> {
        Ok(self.connection.query_row(
            "SELECT id,list_id,title,note,status,due_date,completed_at,created_at,updated_at FROM task WHERE id=?1",
            [id],
            row_to_task,
        ).optional()?)
    }

    pub fn save_runtime(&self, runtime: &Runtime) -> StoreResult<()> {
        self.connection.execute(
            "INSERT INTO runtime(kind,launch_path,resolved_path,version,status,auth_status,capabilities,provider_engine,detected_at,verified_at,verify_error)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
             ON CONFLICT(kind) DO UPDATE SET launch_path=excluded.launch_path,resolved_path=excluded.resolved_path,
             version=excluded.version,status=excluded.status,auth_status=excluded.auth_status,
             capabilities=excluded.capabilities,provider_engine=excluded.provider_engine,
             detected_at=excluded.detected_at,verified_at=excluded.verified_at,verify_error=excluded.verify_error",
            params![
                runtime.kind.as_str(), runtime.launch_path, runtime.resolved_path, runtime.version,
                runtime.status, runtime.auth_status, runtime.capabilities.to_string(),
                runtime.provider_engine, runtime.detected_at, runtime.verified_at, runtime.verify_error
            ],
        )?;
        Ok(())
    }

    pub fn runtime(&self, kind: RuntimeKind) -> StoreResult<Option<Runtime>> {
        Ok(self.connection.query_row(
            "SELECT kind,launch_path,resolved_path,version,status,auth_status,capabilities,provider_engine,detected_at,verified_at,verify_error FROM runtime WHERE kind=?1",
            [kind.as_str()],
            row_to_runtime,
        ).optional()?)
    }

    pub fn runtimes(&self) -> StoreResult<Vec<Runtime>> {
        let mut statement = self.connection.prepare(
            "SELECT kind,launch_path,resolved_path,version,status,auth_status,capabilities,provider_engine,detected_at,verified_at,verify_error FROM runtime ORDER BY kind",
        )?;
        Ok(statement
            .query_map([], row_to_runtime)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    pub fn create_session(
        &self,
        task_id: &str,
        runtime_kind: RuntimeKind,
        working_directory: &str,
        client_message_id: &str,
        prompt: &str,
    ) -> StoreResult<QueuedTurn> {
        validate_uuid(client_message_id)?;
        if self.session_for_task(task_id)?.is_some() {
            return Err(StoreError::Conflict("session_exists"));
        }
        if self.task(task_id)?.is_none() {
            return Err(StoreError::NotFound);
        }
        let timestamp = now();
        let session_id = Uuid::new_v4().to_string();
        let turn_id = Uuid::new_v4().to_string();
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO task_session(id,task_id,runtime_kind,working_directory,provider_engine,state,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,'queued',?6,?6)",
            params![session_id, task_id, runtime_kind.as_str(), working_directory,
                (runtime_kind == RuntimeKind::Kiro).then_some("v2"), timestamp],
        )?;
        transaction.execute(
            "INSERT INTO session_turn(id,session_id,ordinal,user_message_id,status,created_at)
             VALUES(?1,?2,1,?3,'queued',?4)",
            params![turn_id, session_id, client_message_id, timestamp],
        )?;
        transaction.execute(
            "INSERT INTO session_message(id,session_id,turn_id,sequence,client_message_id,role,kind,body,created_at,updated_at)
             VALUES(?1,?2,?3,1,?4,'user','text',?5,?6,?6)",
            params![Uuid::new_v4().to_string(), session_id, turn_id, client_message_id, prompt, timestamp],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(QueuedTurn {
            session: self.session(&session_id)?.ok_or(StoreError::NotFound)?,
            turn: self.turn(&turn_id)?.ok_or(StoreError::NotFound)?,
            prompt: prompt.to_owned(),
            is_new: true,
        })
    }

    pub fn send_message(
        &self,
        session_id: &str,
        client_message_id: &str,
        prompt: &str,
    ) -> StoreResult<QueuedTurn> {
        validate_uuid(client_message_id)?;
        if let Some((turn_id, body)) = self.connection.query_row(
            "SELECT turn_id,body FROM session_message WHERE session_id=?1 AND client_message_id=?2",
            params![session_id, client_message_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        ).optional()? {
            return Ok(QueuedTurn {
                session: self.session(session_id)?.ok_or(StoreError::NotFound)?,
                turn: self.turn(&turn_id)?.ok_or(StoreError::NotFound)?,
                prompt: body,
                is_new: false,
            });
        }
        let session = self.session(session_id)?.ok_or(StoreError::NotFound)?;
        if matches!(session.state, SessionState::Queued | SessionState::Running) {
            return Err(StoreError::Conflict("session_busy"));
        }
        if session.state == SessionState::Closed {
            return Err(StoreError::Conflict("session_closed"));
        }
        let timestamp = now();
        let turn_id = Uuid::new_v4().to_string();
        let transaction = self.connection.unchecked_transaction()?;
        let ordinal: i64 = transaction.query_row(
            "SELECT coalesce(max(ordinal),0)+1 FROM session_turn WHERE session_id=?1",
            [session_id],
            |row| row.get(0),
        )?;
        let sequence = next_message_sequence(&transaction, session_id)?;
        transaction.execute(
            "INSERT INTO session_turn(id,session_id,ordinal,user_message_id,provider_session_id_before,status,created_at)
             VALUES(?1,?2,?3,?4,?5,'queued',?6)",
            params![turn_id, session_id, ordinal, client_message_id, session.provider_session_id, timestamp],
        )?;
        transaction.execute(
            "INSERT INTO session_message(id,session_id,turn_id,sequence,client_message_id,role,kind,body,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,'user','text',?6,?7,?7)",
            params![Uuid::new_v4().to_string(), session_id, turn_id, sequence, client_message_id, prompt, timestamp],
        )?;
        transaction.execute(
            "UPDATE task_session SET state='queued',last_error_code=NULL,last_error_message=NULL,updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(QueuedTurn {
            session: self.session(session_id)?.ok_or(StoreError::NotFound)?,
            turn: self.turn(&turn_id)?.ok_or(StoreError::NotFound)?,
            prompt: prompt.to_owned(),
            is_new: true,
        })
    }

    pub fn mark_turn_running(&self, turn_id: &str) -> StoreResult<SessionTurn> {
        let timestamp = now();
        let transaction = self.connection.unchecked_transaction()?;
        let session_id: String = transaction
            .query_row(
                "SELECT session_id FROM session_turn WHERE id=?1 AND status='queued'",
                [turn_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        transaction.execute(
            "UPDATE session_turn SET status='running',started_at=?1 WHERE id=?2",
            params![timestamp, turn_id],
        )?;
        transaction.execute(
            "UPDATE task_session SET state='running',updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.turn(turn_id)?.ok_or(StoreError::NotFound)
    }

    pub fn set_provider_session(
        &self,
        session_id: &str,
        provider_session_id: &str,
    ) -> StoreResult<()> {
        self.connection.execute(
            "UPDATE task_session SET provider_session_id=?1,updated_at=?2 WHERE id=?3",
            params![provider_session_id, now(), session_id],
        )?;
        Ok(())
    }

    pub fn clear_provider_session(&self, session_id: &str) -> StoreResult<()> {
        self.connection.execute(
            "UPDATE task_session SET provider_session_id=NULL,updated_at=?1 WHERE id=?2",
            params![now(), session_id],
        )?;
        Ok(())
    }

    pub fn recovery_context(&self, session_id: &str, max_bytes: usize) -> StoreResult<String> {
        let task: Task = self.connection.query_row(
            "SELECT t.id,t.list_id,t.title,t.note,t.status,t.due_date,t.completed_at,t.created_at,t.updated_at
             FROM task t JOIN task_session s ON s.task_id=t.id WHERE s.id=?1",
            [session_id],
            row_to_task,
        ).optional()?.ok_or(StoreError::NotFound)?;
        let mut statement = self.connection.prepare(
            "SELECT role,body FROM session_message WHERE session_id=?1 AND role IN ('user','agent') ORDER BY sequence DESC",
        )?;
        let rows = statement
            .query_map([session_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut selected = Vec::new();
        let mut size = 0usize;
        for (role, body) in rows {
            let entry = format!("{role}: {body}");
            if size + entry.len() > max_bytes {
                break;
            }
            size += entry.len();
            selected.push(entry);
        }
        selected.reverse();
        Ok(format!(
            "TodoAgent 正在重建一个失效的本地 Agent Session。\n任务：{}\n说明：{}\n\n最近对话：\n{}\n\n请保持上下文连续，继续处理最后一条用户消息。",
            task.title,
            task.note,
            selected.join("\n\n")
        ))
    }

    pub fn append_agent_text(&self, turn_id: &str, chunk: &str) -> StoreResult<SessionMessage> {
        if chunk.is_empty() {
            return Err(StoreError::Invalid("message chunk is empty".to_owned()));
        }
        let transaction = self.connection.unchecked_transaction()?;
        let session_id: String = transaction
            .query_row(
                "SELECT session_id FROM session_turn WHERE id=?1",
                [turn_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        let existing: Option<String> = transaction.query_row(
            "SELECT id FROM session_message WHERE turn_id=?1 AND role='agent' AND kind='text' ORDER BY sequence LIMIT 1",
            [turn_id],
            |row| row.get(0),
        ).optional()?;
        let timestamp = now();
        let id = if let Some(id) = existing {
            transaction.execute(
                "UPDATE session_message SET body=body||?1,updated_at=?2 WHERE id=?3",
                params![chunk, timestamp, id],
            )?;
            id
        } else {
            let id = Uuid::new_v4().to_string();
            let sequence = next_message_sequence(&transaction, &session_id)?;
            transaction.execute(
                "INSERT INTO session_message(id,session_id,turn_id,sequence,role,kind,body,created_at,updated_at)
                 VALUES(?1,?2,?3,?4,'agent','text',?5,?6,?6)",
                params![id, session_id, turn_id, sequence, chunk, timestamp],
            )?;
            transaction.execute(
                "UPDATE task_session SET last_agent_sequence=?1,updated_at=?2 WHERE id=?3",
                params![sequence, timestamp, session_id],
            )?;
            id
        };
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.message(&id)?.ok_or(StoreError::NotFound)
    }

    pub fn append_message(
        &self,
        turn_id: &str,
        role: MessageRole,
        kind: &str,
        body: &str,
        payload_json: Option<&str>,
    ) -> StoreResult<SessionMessage> {
        let transaction = self.connection.unchecked_transaction()?;
        let session_id: String = transaction
            .query_row(
                "SELECT session_id FROM session_turn WHERE id=?1",
                [turn_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        let sequence = next_message_sequence(&transaction, &session_id)?;
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        transaction.execute(
            "INSERT INTO session_message(id,session_id,turn_id,sequence,role,kind,body,payload_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?9)",
            params![id, session_id, turn_id, sequence, role.as_str(), kind, body, payload_json, timestamp],
        )?;
        if role == MessageRole::Agent && kind == "text" {
            transaction.execute(
                "UPDATE task_session SET last_agent_sequence=?1,updated_at=?2 WHERE id=?3",
                params![sequence, timestamp, session_id],
            )?;
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.message(&id)?.ok_or(StoreError::NotFound)
    }

    pub fn append_turn_event(
        &self,
        turn_id: &str,
        event_type: &str,
        payload: &Value,
    ) -> StoreResult<()> {
        let payload = payload.to_string();
        let payload = if payload.len() > 256 * 1024 {
            &payload[..256 * 1024]
        } else {
            &payload
        };
        let sequence: i64 = self.connection.query_row(
            "SELECT coalesce(max(sequence),0)+1 FROM turn_event WHERE turn_id=?1",
            [turn_id],
            |row| row.get(0),
        )?;
        self.connection.execute(
            "INSERT INTO turn_event(turn_id,sequence,type,payload,created_at) VALUES(?1,?2,?3,?4,?5)",
            params![turn_id, sequence, event_type, payload, now()],
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn finish_turn(
        &self,
        turn_id: &str,
        status: TurnStatus,
        exit_code: Option<i32>,
        final_output: Option<&str>,
        provider_session_id: Option<&str>,
        error_code: Option<&str>,
        error_message: Option<&str>,
        provider_usage_json: Option<&str>,
    ) -> StoreResult<SessionBundle> {
        let transaction = self.connection.unchecked_transaction()?;
        let session_id: String = transaction
            .query_row(
                "SELECT session_id FROM session_turn WHERE id=?1",
                [turn_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        let timestamp = now();
        transaction.execute(
            "UPDATE session_turn SET status=?1,exit_code=?2,final_output=?3,provider_session_id_after=?4,
             error_code=?5,error_message=?6,provider_usage_json=?7,ended_at=?8 WHERE id=?9",
            params![status.as_str(), exit_code, final_output, provider_session_id, error_code,
                error_message, provider_usage_json, timestamp, turn_id],
        )?;
        let session_state = if status == TurnStatus::Completed || status == TurnStatus::Cancelled {
            SessionState::Idle
        } else {
            SessionState::Failed
        };
        transaction.execute(
            "UPDATE task_session SET state=?1,provider_session_id=coalesce(?2,provider_session_id),
             last_error_code=?3,last_error_message=?4,updated_at=?5 WHERE id=?6",
            params![
                session_state.as_str(),
                provider_session_id,
                error_code,
                error_message,
                timestamp,
                session_id
            ],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.session_bundle(&session_id, 0, 1000)
    }

    pub fn session_bundle(
        &self,
        session_id: &str,
        after_sequence: i64,
        limit: i64,
    ) -> StoreResult<SessionBundle> {
        let session = self.session(session_id)?.ok_or(StoreError::NotFound)?;
        let mut statement = self.connection.prepare(
            "SELECT id,session_id,turn_id,sequence,client_message_id,role,kind,body,payload_json,created_at,updated_at
             FROM session_message WHERE session_id=?1 AND sequence>?2 ORDER BY sequence LIMIT ?3",
        )?;
        let messages = statement
            .query_map(
                params![session_id, after_sequence, limit.clamp(1, 2000)],
                row_to_message,
            )?
            .collect::<Result<Vec<_>, _>>()?;
        let active_turn = self.connection.query_row(
            "SELECT id,session_id,ordinal,user_message_id,provider_session_id_before,provider_session_id_after,status,
             exit_code,final_output,error_code,error_message,provider_usage_json,started_at,ended_at,created_at
             FROM session_turn WHERE session_id=?1 AND status IN ('queued','running') ORDER BY ordinal DESC LIMIT 1",
            [session_id],
            row_to_turn,
        ).optional()?;
        Ok(SessionBundle {
            session,
            messages,
            active_turn,
        })
    }

    pub fn session_for_task(&self, task_id: &str) -> StoreResult<Option<TaskSession>> {
        Ok(self
            .connection
            .query_row(
                &session_select("WHERE task_id=?1"),
                [task_id],
                row_to_session,
            )
            .optional()?)
    }

    pub fn session(&self, id: &str) -> StoreResult<Option<TaskSession>> {
        Ok(self
            .connection
            .query_row(&session_select("WHERE id=?1"), [id], row_to_session)
            .optional()?)
    }

    pub fn mark_read(&self, session_id: &str, through_sequence: i64) -> StoreResult<TaskSession> {
        let transaction = self.connection.unchecked_transaction()?;
        let changed = transaction.execute(
            "UPDATE task_session SET last_read_sequence=min(max(last_read_sequence,?1),last_agent_sequence),updated_at=?2 WHERE id=?3",
            params![through_sequence, now(), session_id],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.session(session_id)?.ok_or(StoreError::NotFound)
    }

    pub fn turn(&self, id: &str) -> StoreResult<Option<SessionTurn>> {
        Ok(self.connection.query_row(
            "SELECT id,session_id,ordinal,user_message_id,provider_session_id_before,provider_session_id_after,status,
             exit_code,final_output,error_code,error_message,provider_usage_json,started_at,ended_at,created_at
             FROM session_turn WHERE id=?1",
            [id],
            row_to_turn,
        ).optional()?)
    }

    fn message(&self, id: &str) -> StoreResult<Option<SessionMessage>> {
        Ok(self.connection.query_row(
            "SELECT id,session_id,turn_id,sequence,client_message_id,role,kind,body,payload_json,created_at,updated_at
             FROM session_message WHERE id=?1",
            [id],
            row_to_message,
        ).optional()?)
    }

    fn lists(&self) -> StoreResult<Vec<List>> {
        let mut statement = self.connection.prepare(
            "SELECT id,name,color,repository_path,archived_at,created_at,updated_at FROM list WHERE archived_at IS NULL ORDER BY created_at",
        )?;
        Ok(statement
            .query_map([], |row| {
                Ok(List {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    color: row.get(2)?,
                    repository_path: row.get(3)?,
                    archived_at: row.get(4)?,
                    created_at: row.get(5)?,
                    updated_at: row.get(6)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?)
    }

    fn tasks(&self) -> StoreResult<Vec<Task>> {
        let mut statement = self.connection.prepare(
            "SELECT id,list_id,title,note,status,due_date,completed_at,created_at,updated_at FROM task ORDER BY updated_at DESC",
        )?;
        Ok(statement
            .query_map([], row_to_task)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    fn sessions(&self) -> StoreResult<Vec<TaskSession>> {
        let mut statement = self
            .connection
            .prepare(&session_select("ORDER BY updated_at DESC"))?;
        Ok(statement
            .query_map([], row_to_session)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    fn reconcile_interrupted_turns(&self) -> StoreResult<()> {
        let transaction = self.connection.unchecked_transaction()?;
        let timestamp = now();
        let mut statement = transaction.prepare(
            "SELECT id,session_id FROM session_turn WHERE status IN ('queued','running')",
        )?;
        let interrupted = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        for (turn_id, session_id) in &interrupted {
            transaction.execute(
                "UPDATE session_turn SET status='interrupted',error_code='engine_interrupted',
                 error_message='TodoAgent 上次退出时本轮仍在运行',ended_at=?1 WHERE id=?2",
                params![timestamp, turn_id],
            )?;
            let sequence = next_message_sequence(&transaction, session_id)?;
            transaction.execute(
                "INSERT INTO session_message(id,session_id,turn_id,sequence,role,kind,body,created_at,updated_at)
                 VALUES(?1,?2,?3,?4,'system','error','TodoAgent 上次退出时本轮仍在运行，请重新发送消息继续。',?5,?5)",
                params![Uuid::new_v4().to_string(), session_id, turn_id, sequence, timestamp],
            )?;
            transaction.execute(
                "UPDATE task_session SET state='failed',last_error_code='engine_interrupted',
                 last_error_message='TodoAgent 上次退出时本轮仍在运行',updated_at=?1 WHERE id=?2",
                params![timestamp, session_id],
            )?;
        }
        if !interrupted.is_empty() {
            bump_revision(&transaction)?;
        }
        transaction.commit()?;
        Ok(())
    }
}

fn migrate(connection: &Connection) -> StoreResult<()> {
    let has_legacy = table_exists(connection, "schema_version")?
        && !table_exists(connection, "schema_migration")?;
    if has_legacy {
        connection.pragma_update(None, "foreign_keys", "OFF")?;
        connection.execute_batch(
            "DROP INDEX IF EXISTS idx_task_status;
             DROP INDEX IF EXISTS idx_task_list;
             DROP INDEX IF EXISTS idx_run_task;
             DROP INDEX IF EXISTS idx_event_run;
             DROP INDEX IF EXISTS idx_chat_message_session;
             DROP TABLE IF EXISTS run_event;
             DROP TABLE IF EXISTS attempt;
             DROP TABLE IF EXISTS task_message;
             DROP TABLE IF EXISTS run;
             DROP TABLE IF EXISTS attachment;
             DROP TABLE IF EXISTS chat_message;
             DROP TABLE IF EXISTS chat_session;
             ALTER TABLE task RENAME TO task_legacy;
             ALTER TABLE runtime RENAME TO runtime_legacy;",
        )?;
        connection.execute_batch(include_str!("schema.sql"))?;
        connection.execute_batch(
            "INSERT INTO task(id,list_id,title,note,status,due_date,completed_at,created_at,updated_at)
             SELECT id,list_id,title,note,CASE WHEN status='done' THEN 'completed' ELSE 'open' END,due_date,
                    CASE WHEN status='done' THEN updated_at ELSE NULL END,created_at,updated_at
             FROM task_legacy;
             DROP TABLE task_legacy;
             DROP TABLE runtime_legacy;
             DROP TABLE schema_version;"
        )?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
    } else {
        connection.execute_batch(include_str!("schema.sql"))?;
    }
    connection.execute(
        "INSERT OR IGNORE INTO schema_migration(version,name,checksum,applied_at) VALUES(?1,'session model',?2,?3)",
        params![SCHEMA_VERSION, SCHEMA_CHECKSUM, now()],
    )?;
    Ok(())
}

fn table_exists(connection: &Connection, name: &str) -> rusqlite::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1",
            [name],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn bump_revision(transaction: &Transaction<'_>) -> rusqlite::Result<()> {
    transaction.execute(
        "UPDATE app_revision SET revision=revision+1 WHERE singleton=1",
        [],
    )?;
    Ok(())
}

fn next_message_sequence(transaction: &Transaction<'_>, session_id: &str) -> rusqlite::Result<i64> {
    transaction.query_row(
        "SELECT coalesce(max(sequence),0)+1 FROM session_message WHERE session_id=?1",
        [session_id],
        |row| row.get(0),
    )
}

fn session_select(suffix: &str) -> String {
    format!(
        "SELECT id,task_id,runtime_kind,working_directory,provider_session_id,provider_engine,state,
         last_agent_sequence,last_read_sequence,last_error_code,last_error_message,created_at,updated_at
         FROM task_session {suffix}"
    )
}

fn row_to_task(row: &rusqlite::Row<'_>) -> rusqlite::Result<Task> {
    let raw: String = row.get(4)?;
    Ok(Task {
        id: row.get(0)?,
        list_id: row.get(1)?,
        title: row.get(2)?,
        note: row.get(3)?,
        status: TaskStatus::parse(&raw).ok_or(rusqlite::Error::InvalidQuery)?,
        due_date: row.get(5)?,
        completed_at: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

fn row_to_runtime(row: &rusqlite::Row<'_>) -> rusqlite::Result<Runtime> {
    let raw: String = row.get(0)?;
    let capabilities: String = row.get(6)?;
    Ok(Runtime {
        kind: RuntimeKind::parse(&raw).ok_or(rusqlite::Error::InvalidQuery)?,
        launch_path: row.get(1)?,
        resolved_path: row.get(2)?,
        version: row.get(3)?,
        status: row.get(4)?,
        auth_status: row.get(5)?,
        capabilities: serde_json::from_str(&capabilities).unwrap_or_else(|_| json!({})),
        provider_engine: row.get(7)?,
        detected_at: row.get(8)?,
        verified_at: row.get(9)?,
        verify_error: row.get(10)?,
    })
}

fn row_to_session(row: &rusqlite::Row<'_>) -> rusqlite::Result<TaskSession> {
    let runtime: String = row.get(2)?;
    let state: String = row.get(6)?;
    Ok(TaskSession {
        id: row.get(0)?,
        task_id: row.get(1)?,
        runtime_kind: RuntimeKind::parse(&runtime).ok_or(rusqlite::Error::InvalidQuery)?,
        working_directory: row.get(3)?,
        provider_session_id: row.get(4)?,
        provider_engine: row.get(5)?,
        state: SessionState::parse(&state).ok_or(rusqlite::Error::InvalidQuery)?,
        last_agent_sequence: row.get(7)?,
        last_read_sequence: row.get(8)?,
        last_error_code: row.get(9)?,
        last_error_message: row.get(10)?,
        created_at: row.get(11)?,
        updated_at: row.get(12)?,
    })
}

fn row_to_turn(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionTurn> {
    let status: String = row.get(6)?;
    Ok(SessionTurn {
        id: row.get(0)?,
        session_id: row.get(1)?,
        ordinal: row.get(2)?,
        user_message_id: row.get(3)?,
        provider_session_id_before: row.get(4)?,
        provider_session_id_after: row.get(5)?,
        status: TurnStatus::parse(&status).ok_or(rusqlite::Error::InvalidQuery)?,
        exit_code: row.get(7)?,
        final_output: row.get(8)?,
        error_code: row.get(9)?,
        error_message: row.get(10)?,
        provider_usage_json: row.get(11)?,
        started_at: row.get(12)?,
        ended_at: row.get(13)?,
        created_at: row.get(14)?,
    })
}

fn row_to_message(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionMessage> {
    let role: String = row.get(5)?;
    Ok(SessionMessage {
        id: row.get(0)?,
        session_id: row.get(1)?,
        turn_id: row.get(2)?,
        sequence: row.get(3)?,
        client_message_id: row.get(4)?,
        role: MessageRole::parse(&role).ok_or(rusqlite::Error::InvalidQuery)?,
        kind: row.get(6)?,
        body: row.get(7)?,
        payload_json: row.get(8)?,
        created_at: row.get(9)?,
        updated_at: row.get(10)?,
    })
}

fn validate_uuid(value: &str) -> StoreResult<()> {
    Uuid::parse_str(value)
        .map(|_| ())
        .map_err(|_| StoreError::Invalid("clientMessageId must be a UUID".to_owned()))
}

fn now() -> String {
    Utc::now().to_rfc3339()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn fresh_database_round_trips_session_and_unread() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let list = store
            .create_list("产品", "blue", Some("/tmp/repo"))
            .unwrap();
        let task = store
            .create_task("完成原生版", "接通后端", Some(&list.id), Some("2026-08-08"))
            .unwrap();
        let queued = store
            .create_session(
                &task.id,
                RuntimeKind::Codex,
                "/tmp/repo",
                &Uuid::new_v4().to_string(),
                "完成原生版\n\n接通后端",
            )
            .unwrap();
        store.mark_turn_running(&queued.turn.id).unwrap();
        let message = store.append_agent_text(&queued.turn.id, "完成").unwrap();
        store
            .finish_turn(
                &queued.turn.id,
                TurnStatus::Completed,
                Some(0),
                Some("完成"),
                Some("provider-1"),
                None,
                None,
                None,
            )
            .unwrap();

        let bundle = store.session_bundle(&queued.session.id, 0, 100).unwrap();
        assert_eq!(bundle.messages.len(), 2);
        assert_eq!(bundle.messages[1], message);
        assert!(bundle.session.last_agent_sequence > bundle.session.last_read_sequence);
        let read = store
            .mark_read(&queued.session.id, message.sequence)
            .unwrap();
        assert!(read.last_agent_sequence <= read.last_read_sequence);
        assert_eq!(store.health().unwrap()["schemaVersion"], 2);
    }

    #[test]
    fn client_message_id_is_idempotent() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("任务", "", None, None).unwrap();
        let client_id = Uuid::new_v4().to_string();
        let first = store
            .create_session(&task.id, RuntimeKind::Claude, "/tmp", &client_id, "任务")
            .unwrap();
        let duplicate = store
            .send_message(&first.session.id, &client_id, "任务")
            .unwrap();
        assert_eq!(first.turn.id, duplicate.turn.id);
        assert!(!duplicate.is_new);
    }

    #[test]
    fn only_one_active_turn_is_allowed_per_session() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("任务", "", None, None).unwrap();
        let first = store
            .create_session(
                &task.id,
                RuntimeKind::Cursor,
                "/tmp",
                &Uuid::new_v4().to_string(),
                "任务",
            )
            .unwrap();
        let error = store
            .send_message(&first.session.id, &Uuid::new_v4().to_string(), "继续")
            .unwrap_err();
        assert!(matches!(error, StoreError::Conflict("session_busy")));
    }
}
