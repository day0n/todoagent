use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::fs;
use std::io;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use chrono::{Datelike, NaiveDate, Utc};
use rusqlite::types::Value as SqlValue;
use rusqlite::{Connection, OptionalExtension, Transaction, params, params_from_iter};
use serde::Deserialize;
use serde_json::{Value, json};
use thiserror::Error;
use uuid::Uuid;

use crate::models::{
    AssistantCompaction, AssistantContextHistory, AssistantHistory, AssistantMessage,
    AssistantSession, AssistantStep, AssistantToolExecution, AssistantToolResult,
    AssistantToolSummary, AssistantTurn, AssistantTurnStatus, Bootstrap, CreateTaskInput, List,
    ProviderBindingState, QueuedAssistantTurn, Runtime, RuntimeKind, SessionTimelineItem, Task,
    TaskAttachment, TaskState, TaskStatus, TerminalAgentStatus, TerminalLaunchMode, TerminalRun,
    TerminalRunState, TerminalSession, TerminalSessionBundle, UpdateTaskInput,
};

pub const SCHEMA_VERSION: i64 = 5;
const SCHEMA_CHECKSUM: &str = "todoagent-native-v5-terminal-sessions-receipts";
const ASSISTANT_TOOL_RESULT_MAX_BYTES: usize = 8 * 1024;
const ASSISTANT_FILTERED_TASK_PAGE_SIZE: usize = 50;
const SESSION_TIMELINE_PAYLOAD_MAX_BYTES: usize = 256 * 1024;
const SESSION_TIMELINE_TEXT_MAX_BYTES: usize = 1024 * 1024;
const SESSION_TIMELINE_REASONING_MAX_BYTES: usize = 256 * 1024;
const ASSISTANT_HISTORY_MESSAGE_PAGE_MAX_BYTES: usize = 8 * 1024 * 1024;
const ASSISTANT_HISTORY_DETAIL_PAGE_MAX_BYTES: usize = 8 * 1024 * 1024;
const ASSISTANT_HISTORY_PARTIAL_NOTICE_RESERVE_BYTES: usize = 4 * 1024;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TaskPageCursor {
    task_revision: i64,
    status: TaskStatus,
    updated_at: String,
    task_id: String,
    #[serde(default)]
    filter_execution_date: Option<String>,
    #[serde(default)]
    filter_status: Option<TaskStatus>,
    #[serde(default)]
    filter_list_id: Option<String>,
}

#[derive(Debug, Error)]
pub enum StoreError {
    #[error(transparent)]
    Sql(#[from] rusqlite::Error),
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error("record not found")]
    NotFound,
    #[error("{0}")]
    Conflict(&'static str),
    #[error("{0}")]
    Invalid(String),
}

pub type StoreResult<T> = Result<T, StoreError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentMutationOutcome {
    Applied,
    Replayed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoveTaskAttachmentPreparation {
    Pending(TaskAttachment),
    Replayed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AssistantDeleteTaskOutcome {
    Applied(AssistantToolResult),
    Replayed(AssistantToolResult),
}

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
        store.reconcile_interrupted_terminal_runs()?;
        store.reconcile_interrupted_assistant_turns()?;
        store.repair_terminal_assistant_turns()?;
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
            task_attachments: self.task_attachments()?,
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
        let name = normalize_list_name(name)?;
        let now = now();
        let list = List {
            id: Uuid::new_v4().to_string(),
            name,
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

    /// Renames one list without changing any task membership.
    pub fn rename_list(&self, list_id: &str, name: &str) -> StoreResult<List> {
        let list_id = canonical_uuid(list_id, "listId")?;
        let name = normalize_list_name(name)?;
        let timestamp = now();
        let transaction = self.connection.unchecked_transaction()?;
        let changed = transaction.execute(
            "UPDATE list SET name=?1,updated_at=?2 WHERE id=?3",
            params![name, timestamp, list_id],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.connection
            .query_row(
                "SELECT id,name,color,repository_path,archived_at,created_at,updated_at
                 FROM list WHERE id=?1",
                [&list_id],
                row_to_list,
            )
            .map_err(StoreError::from)
    }

    /// Deletes only the list container. Tasks remain canonical task records and
    /// are moved back to the unlisted Tasks view in the same transaction.
    pub fn delete_list(&self, list_id: &str) -> StoreResult<()> {
        let list_id = canonical_uuid(list_id, "listId")?;
        let timestamp = now();
        let transaction = self.connection.unchecked_transaction()?;
        let exists = transaction
            .query_row("SELECT 1 FROM list WHERE id=?1", [&list_id], |_| Ok(()))
            .optional()?
            .is_some();
        if !exists {
            return Err(StoreError::NotFound);
        }
        let moved_tasks = transaction.execute(
            "UPDATE task SET list_id=NULL,updated_at=?1 WHERE list_id=?2",
            params![timestamp, list_id],
        )?;
        transaction.execute("DELETE FROM list WHERE id=?1", [&list_id])?;
        if moved_tasks > 0 {
            bump_task_data_revision(&transaction)?;
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    /// Creates a blue list from the task title and moves the source task into it.
    ///
    /// Task titles may be longer than list names, so truncation is performed by
    /// Unicode scalar value rather than byte offset. The list insert, task move,
    /// and both observable revision increments are one transaction.
    pub fn create_list_from_task(&self, task_id: &str) -> StoreResult<List> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        let transaction = self.connection.unchecked_transaction()?;
        let task_title: String = transaction
            .query_row("SELECT title FROM task WHERE id=?1", [&task_id], |row| {
                row.get(0)
            })
            .optional()?
            .ok_or(StoreError::NotFound)?;
        let list_name = task_title.trim().chars().take(200).collect::<String>();
        if list_name.is_empty() {
            return Err(StoreError::Invalid(
                "task title cannot create an empty list name".to_owned(),
            ));
        }
        let timestamp = now();
        let list = List {
            id: Uuid::new_v4().to_string(),
            name: list_name,
            color: "blue".to_owned(),
            repository_path: None,
            archived_at: None,
            created_at: timestamp.clone(),
            updated_at: timestamp.clone(),
        };
        transaction.execute(
            "INSERT INTO list(id,name,color,repository_path,created_at,updated_at)
             VALUES(?1,?2,?3,NULL,?4,?5)",
            params![
                list.id,
                list.name,
                list.color,
                list.created_at,
                list.updated_at
            ],
        )?;
        transaction.execute(
            "UPDATE task SET list_id=?1,updated_at=?2 WHERE id=?3",
            params![list.id, timestamp, task_id],
        )?;
        bump_task_data_revision(&transaction)?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(list)
    }

    pub fn create_task(
        &self,
        title: &str,
        note: &str,
        list_id: Option<&str>,
        execution_date: Option<&str>,
        due_date: Option<&str>,
    ) -> StoreResult<Task> {
        let list_id = list_id
            .map(|value| canonical_uuid(value, "listId"))
            .transpose()?;
        validate_task_input(&CreateTaskInput {
            title: title.to_owned(),
            note: note.to_owned(),
            list_id: list_id.clone(),
            execution_date: execution_date.map(str::to_owned),
            due_date: due_date.map(str::to_owned),
        })?;
        if let Some(id) = list_id.as_deref() {
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
            list_id,
            title: title.trim().to_owned(),
            note: note.to_owned(),
            status: TaskStatus::Open,
            execution_date: execution_date.map(str::to_owned),
            due_date: due_date.map(str::to_owned),
            completed_at: None,
            created_at: timestamp.clone(),
            updated_at: timestamp,
        };
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO task(id,list_id,title,note,status,execution_date,due_date,created_at,updated_at) VALUES(?1,?2,?3,?4,'open',?5,?6,?7,?8)",
            params![task.id, task.list_id, task.title, task.note, task.execution_date, task.due_date, task.created_at, task.updated_at],
        )?;
        bump_task_data_revision(&transaction)?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(task)
    }

    /// Creates between one and ten tasks atomically. Every input is validated before
    /// the first row is inserted, so a bad list reference cannot leave partial work.
    #[allow(dead_code)]
    pub fn create_tasks(&self, inputs: &[CreateTaskInput]) -> StoreResult<Vec<Task>> {
        if !(1..=10).contains(&inputs.len()) {
            return Err(StoreError::Invalid(
                "create_tasks accepts between 1 and 10 tasks".to_owned(),
            ));
        }
        for input in inputs {
            validate_task_input(input)?;
        }

        let transaction = self.connection.unchecked_transaction()?;
        for list_id in inputs.iter().filter_map(|input| input.list_id.as_deref()) {
            let list_id = canonical_uuid(list_id, "listId")?;
            let exists: Option<i64> = transaction
                .query_row(
                    "SELECT 1 FROM list WHERE id=?1 AND archived_at IS NULL",
                    [&list_id],
                    |row| row.get(0),
                )
                .optional()?;
            if exists.is_none() {
                return Err(StoreError::NotFound);
            }
        }

        let timestamp = now();
        let mut tasks = Vec::with_capacity(inputs.len());
        for input in inputs {
            let task = Task {
                id: Uuid::new_v4().to_string(),
                list_id: input
                    .list_id
                    .as_deref()
                    .map(|value| canonical_uuid(value, "listId"))
                    .transpose()?,
                title: input.title.trim().to_owned(),
                note: input.note.clone(),
                status: TaskStatus::Open,
                execution_date: input.execution_date.clone(),
                due_date: input.due_date.clone(),
                completed_at: None,
                created_at: timestamp.clone(),
                updated_at: timestamp.clone(),
            };
            transaction.execute(
                "INSERT INTO task(id,list_id,title,note,status,execution_date,due_date,created_at,updated_at)
                 VALUES(?1,?2,?3,?4,'open',?5,?6,?7,?8)",
                params![
                    task.id,
                    task.list_id,
                    task.title,
                    task.note,
                    task.execution_date,
                    task.due_date,
                    task.created_at,
                    task.updated_at
                ],
            )?;
            tasks.push(task);
        }
        bump_task_data_revision(&transaction)?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(tasks)
    }

    #[allow(dead_code)]
    pub fn update_task(&self, id: &str, update: &UpdateTaskInput) -> StoreResult<Task> {
        let id = canonical_uuid(id, "taskId")?;
        validate_task_update(update)?;
        let transaction = self.connection.unchecked_transaction()?;
        let existing: Task = transaction
            .query_row(
                "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at FROM task WHERE id=?1",
                [&id],
                row_to_task,
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        let list_id = update
            .list_id
            .clone()
            .unwrap_or(existing.list_id)
            .map(|value| canonical_uuid(&value, "listId"))
            .transpose()?;
        if let Some(list_id) = list_id.as_deref() {
            let exists: Option<i64> = transaction
                .query_row(
                    "SELECT 1 FROM list WHERE id=?1 AND archived_at IS NULL",
                    [list_id],
                    |row| row.get(0),
                )
                .optional()?;
            if exists.is_none() {
                return Err(StoreError::NotFound);
            }
        }
        let status = update.status.unwrap_or(existing.status);
        let timestamp = now();
        let completed_at = if status == TaskStatus::Completed {
            existing
                .completed_at
                .clone()
                .or_else(|| Some(timestamp.clone()))
        } else {
            None
        };
        transaction.execute(
            "UPDATE task SET list_id=?1,title=?2,note=?3,status=?4,execution_date=?5,due_date=?6,completed_at=?7,updated_at=?8 WHERE id=?9",
            params![
                list_id,
                update.title.as_deref().unwrap_or(&existing.title).trim(),
                update.note.as_deref().unwrap_or(&existing.note),
                status.as_str(),
                update.execution_date.clone().unwrap_or(existing.execution_date),
                update.due_date.clone().unwrap_or(existing.due_date),
                completed_at,
                timestamp,
                id
            ],
        )?;
        bump_task_data_revision(&transaction)?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.task(&id)?.ok_or(StoreError::NotFound)
    }

    #[allow(dead_code)]
    pub fn find_related_tasks(&self, query: &str, limit: i64) -> StoreResult<Vec<Task>> {
        let query = query.trim();
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let pattern = format!("%{query}%");
        let mut statement = self.connection.prepare(
            "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at
             FROM task WHERE title LIKE ?1 OR note LIKE ?1
             ORDER BY CASE WHEN status='open' THEN 0 ELSE 1 END, updated_at DESC LIMIT ?2",
        )?;
        Ok(statement
            .query_map(params![pattern, limit.clamp(1, 10)], row_to_task)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    #[allow(dead_code)]
    pub fn list_state(&self) -> StoreResult<TaskState> {
        Ok(TaskState {
            revision: self.revision()?,
            lists: self.lists()?,
            tasks: self.tasks()?,
        })
    }

    #[allow(dead_code)]
    pub fn list_lists(&self) -> StoreResult<Vec<List>> {
        self.lists()
    }

    pub fn set_task_status(&self, id: &str, status: TaskStatus) -> StoreResult<Task> {
        let id = canonical_uuid(id, "taskId")?;
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
        bump_task_data_revision(&transaction)?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.task(&id)?.ok_or(StoreError::NotFound)
    }

    pub fn task(&self, id: &str) -> StoreResult<Option<Task>> {
        let id = canonical_uuid(id, "taskId")?;
        Ok(self.connection.query_row(
            "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at FROM task WHERE id=?1",
            [&id],
            row_to_task,
        ).optional()?)
    }

    /// Resolves every managed attachment before Engine performs its reversible
    /// filesystem preparation. Active local sessions deliberately block deletion
    /// so a background CLI cannot write through foreign keys after the task and
    /// its session have been cascaded away.
    pub fn prepare_delete_task(&self, task_id: &str) -> StoreResult<Vec<TaskAttachment>> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        if !task_record_exists(&self.connection, &task_id)? {
            return Err(StoreError::NotFound);
        }
        ensure_task_session_inactive(&self.connection, &task_id)?;
        let mut statement = self.connection.prepare(
            "SELECT id,task_id,original_name,size_bytes,mime_type,relative_path,created_at
             FROM task_attachment WHERE task_id=?1 ORDER BY created_at,id",
        )?;
        let attachments = statement
            .query_map([&task_id], row_to_task_attachment)?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        for attachment in &attachments {
            let attachment_id = canonical_uuid(&attachment.id, "attachmentId")?;
            if canonical_uuid(&attachment.task_id, "taskId")? != task_id {
                return Err(StoreError::Invalid(
                    "attachment taskId does not match task deletion".to_owned(),
                ));
            }
            let managed_name = managed_attachment_file_name(&attachment.relative_path)?;
            validate_managed_attachment_name(&managed_name, &attachment_id)?;
        }
        Ok(attachments)
    }

    /// Deletes a task and all foreign-key-owned records in one transaction.
    /// Engine calls this only after attachment files have a recoverable quarantine
    /// link; the active-session check is repeated here to close the preparation
    /// race before the cascading DELETE commits.
    pub fn delete_task(&self, task_id: &str) -> StoreResult<()> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        let transaction = self.connection.unchecked_transaction()?;
        if !task_record_exists(&transaction, &task_id)? {
            return Err(StoreError::NotFound);
        }
        ensure_task_session_inactive(&transaction, &task_id)?;
        let changed = transaction.execute("DELETE FROM task WHERE id=?1", [&task_id])?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        bump_task_data_revision(&transaction)?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    /// Returns true when this exact add request already committed. A caller
    /// must perform this check before copying potentially large source files,
    /// then still use `add_task_attachments_idempotent` to close the race
    /// between this read and the SQLite transaction.
    pub fn prepare_add_task_attachment_mutation(
        &self,
        task_id: &str,
        client_mutation_id: &str,
        source_paths: &[String],
    ) -> StoreResult<bool> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        let client_mutation_id = canonical_uuid(client_mutation_id, "clientMutationId")?;
        validate_attachment_source_paths(source_paths)?;
        let fingerprint = add_attachment_mutation_fingerprint(&task_id, source_paths);
        if attachment_mutation_was_committed(
            &self.connection,
            &client_mutation_id,
            "add",
            &task_id,
            &fingerprint,
        )? {
            return Ok(true);
        }
        if self.task(&task_id)?.is_none() {
            return Err(StoreError::NotFound);
        }
        Ok(false)
    }

    /// Atomically stores attachment rows and their durable idempotency
    /// receipt. Replaying the same canonical request does not insert rows or
    /// advance the snapshot revision.
    pub fn add_task_attachments_idempotent(
        &self,
        task_id: &str,
        client_mutation_id: &str,
        source_paths: &[String],
        attachments: &[TaskAttachment],
    ) -> StoreResult<AttachmentMutationOutcome> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        let client_mutation_id = canonical_uuid(client_mutation_id, "clientMutationId")?;
        validate_attachment_source_paths(source_paths)?;
        if attachments.is_empty() || attachments.len() != source_paths.len() {
            return Err(StoreError::Invalid(
                "staged attachments must match sourcePaths".to_owned(),
            ));
        }
        let fingerprint = add_attachment_mutation_fingerprint(&task_id, source_paths);
        let transaction = self.connection.unchecked_transaction()?;
        if attachment_mutation_was_committed(
            &transaction,
            &client_mutation_id,
            "add",
            &task_id,
            &fingerprint,
        )? {
            return Ok(AttachmentMutationOutcome::Replayed);
        }
        if !task_record_exists(&transaction, &task_id)? {
            return Err(StoreError::NotFound);
        }

        let mut attachment_ids = Vec::with_capacity(attachments.len());
        for attachment in attachments {
            let attachment_task_id = canonical_uuid(&attachment.task_id, "taskId")?;
            if attachment_task_id != task_id {
                return Err(StoreError::Invalid(
                    "attachment taskId does not match request".to_owned(),
                ));
            }
            let attachment_id = canonical_uuid(&attachment.id, "attachmentId")?;
            let managed_name = managed_attachment_file_name(&attachment.relative_path)?;
            validate_managed_attachment_name(&managed_name, &attachment_id)?;
            transaction.execute(
                "INSERT INTO task_attachment(id,task_id,original_name,size_bytes,mime_type,relative_path,created_at)
                 VALUES(?1,?2,?3,?4,?5,?6,?7)",
                params![
                    attachment_id,
                    attachment_task_id,
                    attachment.original_name,
                    attachment.size_bytes,
                    attachment.mime_type,
                    attachment.relative_path,
                    attachment.created_at,
                ],
            )?;
            attachment_ids.push(attachment_id);
        }
        insert_attachment_mutation_receipt(
            &transaction,
            &client_mutation_id,
            "add",
            &task_id,
            &fingerprint,
            &json!(attachment_ids).to_string(),
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(AttachmentMutationOutcome::Applied)
    }

    /// Resolves an idempotent remove before any filesystem rename. A committed
    /// replay succeeds even though its target attachment row is already gone;
    /// a new mutation ID still receives NotFound for an absent target.
    pub fn prepare_remove_task_attachment_mutation(
        &self,
        task_id: &str,
        attachment_id: &str,
        client_mutation_id: &str,
    ) -> StoreResult<RemoveTaskAttachmentPreparation> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        let attachment_id = canonical_uuid(attachment_id, "attachmentId")?;
        let client_mutation_id = canonical_uuid(client_mutation_id, "clientMutationId")?;
        let fingerprint = remove_attachment_mutation_fingerprint(&task_id, &attachment_id);
        if attachment_mutation_was_committed(
            &self.connection,
            &client_mutation_id,
            "remove",
            &task_id,
            &fingerprint,
        )? {
            return Ok(RemoveTaskAttachmentPreparation::Replayed);
        }
        self.task_attachment(&task_id, &attachment_id)?
            .map(RemoveTaskAttachmentPreparation::Pending)
            .ok_or(StoreError::NotFound)
    }

    pub fn remove_task_attachment_idempotent(
        &self,
        task_id: &str,
        attachment_id: &str,
        client_mutation_id: &str,
    ) -> StoreResult<AttachmentMutationOutcome> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        let attachment_id = canonical_uuid(attachment_id, "attachmentId")?;
        let client_mutation_id = canonical_uuid(client_mutation_id, "clientMutationId")?;
        let fingerprint = remove_attachment_mutation_fingerprint(&task_id, &attachment_id);
        let transaction = self.connection.unchecked_transaction()?;
        if attachment_mutation_was_committed(
            &transaction,
            &client_mutation_id,
            "remove",
            &task_id,
            &fingerprint,
        )? {
            return Ok(AttachmentMutationOutcome::Replayed);
        }
        if !task_record_exists(&transaction, &task_id)? {
            return Err(StoreError::NotFound);
        }
        let changed = transaction.execute(
            "DELETE FROM task_attachment WHERE id=?1 AND task_id=?2",
            params![attachment_id, task_id],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        insert_attachment_mutation_receipt(
            &transaction,
            &client_mutation_id,
            "remove",
            &task_id,
            &fingerprint,
            &json!([attachment_id]).to_string(),
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(AttachmentMutationOutcome::Applied)
    }

    #[cfg(test)]
    pub fn add_task_attachments(
        &self,
        task_id: &str,
        attachments: &[TaskAttachment],
    ) -> StoreResult<()> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        if self.task(&task_id)?.is_none() {
            return Err(StoreError::NotFound);
        }
        if attachments.is_empty() {
            return Err(StoreError::Invalid(
                "sourcePaths must contain at least one file".to_owned(),
            ));
        }
        let transaction = self.connection.unchecked_transaction()?;
        for attachment in attachments {
            let attachment_task_id = canonical_uuid(&attachment.task_id, "taskId")?;
            if attachment_task_id != task_id {
                return Err(StoreError::Invalid(
                    "attachment taskId does not match request".to_owned(),
                ));
            }
            let attachment_id = canonical_uuid(&attachment.id, "attachmentId")?;
            let managed_name = managed_attachment_file_name(&attachment.relative_path)?;
            validate_managed_attachment_name(&managed_name, &attachment_id)?;
            transaction.execute(
                "INSERT INTO task_attachment(id,task_id,original_name,size_bytes,mime_type,relative_path,created_at)
                 VALUES(?1,?2,?3,?4,?5,?6,?7)",
                params![
                    attachment_id,
                    attachment_task_id,
                    attachment.original_name,
                    attachment.size_bytes,
                    attachment.mime_type,
                    attachment.relative_path,
                    attachment.created_at,
                ],
            )?;
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn task_attachment(
        &self,
        task_id: &str,
        attachment_id: &str,
    ) -> StoreResult<Option<TaskAttachment>> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        let attachment_id = canonical_uuid(attachment_id, "attachmentId")?;
        Ok(self
            .connection
            .query_row(
                "SELECT id,task_id,original_name,size_bytes,mime_type,relative_path,created_at
                 FROM task_attachment WHERE id=?1 AND task_id=?2",
                params![attachment_id, task_id],
                row_to_task_attachment,
            )
            .optional()?)
    }

    #[cfg(test)]
    pub fn remove_task_attachment(
        &self,
        task_id: &str,
        attachment_id: &str,
    ) -> StoreResult<TaskAttachment> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        let attachment_id = canonical_uuid(attachment_id, "attachmentId")?;
        let transaction = self.connection.unchecked_transaction()?;
        let attachment = transaction
            .query_row(
                "SELECT id,task_id,original_name,size_bytes,mime_type,relative_path,created_at
                 FROM task_attachment WHERE id=?1 AND task_id=?2",
                params![attachment_id, task_id],
                row_to_task_attachment,
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        transaction.execute(
            "DELETE FROM task_attachment WHERE id=?1 AND task_id=?2",
            params![attachment_id, task_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(attachment)
    }

    /// Repairs TodoAgent's private attachment directory after SQLite has
    /// successfully opened at the supported schema. Operations are limited to direct
    /// children and symbolic links are never followed.
    pub fn reconcile_task_attachment_files(&self, attachments: &Path) -> StoreResult<()> {
        ensure_real_directory(attachments)?;
        let mut statement = self
            .connection
            .prepare("SELECT id,relative_path FROM task_attachment")?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        drop(statement);

        // Validate the complete DB projection before touching the filesystem.
        let mut referenced_names = HashSet::<OsString>::new();
        let mut final_name_by_attachment = HashMap::<String, OsString>::new();
        for (raw_id, relative_path) in rows {
            let attachment_id = canonical_uuid(&raw_id, "attachmentId")?;
            let file_name = managed_attachment_file_name(&relative_path)?;
            validate_managed_attachment_name(&file_name, &attachment_id)?;
            referenced_names.insert(file_name.clone());
            final_name_by_attachment.insert(attachment_id, file_name);
        }

        let entries = fs::read_dir(attachments)?.collect::<Result<Vec<_>, _>>()?;
        for entry in entries {
            let path = entry.path();
            let file_name = entry.file_name();
            let metadata = fs::symlink_metadata(&path)?;
            let removable = metadata.is_file() || metadata.file_type().is_symlink();
            let display_name = file_name.to_string_lossy();

            if display_name.starts_with(".staging-") {
                if removable {
                    remove_file_if_present(&path)?;
                }
                continue;
            }

            if let Some(raw_attachment_id) = display_name.strip_prefix(".removing-") {
                if !removable {
                    continue;
                }
                if metadata.file_type().is_symlink() {
                    remove_file_if_present(&path)?;
                    continue;
                }
                let attachment_id = Uuid::parse_str(raw_attachment_id)
                    .ok()
                    .map(|value| value.to_string());
                let Some(final_name) = attachment_id
                    .as_ref()
                    .and_then(|id| final_name_by_attachment.get(id))
                else {
                    remove_file_if_present(&path)?;
                    continue;
                };
                let final_path = attachments.join(final_name);
                let should_restore = match fs::symlink_metadata(&final_path) {
                    Ok(metadata) if metadata.file_type().is_symlink() => {
                        remove_file_if_present(&final_path)?;
                        true
                    }
                    Ok(metadata) if metadata.is_file() => false,
                    Ok(_) => {
                        return Err(StoreError::Invalid(
                            "managed attachment target must be a regular file".to_owned(),
                        ));
                    }
                    Err(error) if error.kind() == io::ErrorKind::NotFound => true,
                    Err(error) => return Err(error.into()),
                };
                if should_restore {
                    // hard_link is exclusive and crash-safe: a crash before
                    // removing quarantine leaves two names for next startup.
                    match fs::hard_link(&path, &final_path) {
                        Ok(()) => remove_file_if_present(&path)?,
                        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                            remove_file_if_present(&path)?;
                        }
                        Err(error) => return Err(error.into()),
                    }
                } else {
                    remove_file_if_present(&path)?;
                }
                continue;
            }

            if metadata.file_type().is_symlink()
                || (metadata.is_file() && !referenced_names.contains(&file_name))
            {
                remove_file_if_present(&path)?;
            }
        }
        Ok(())
    }

    pub fn save_runtime(&self, runtime: &Runtime) -> StoreResult<()> {
        let transaction = self.connection.unchecked_transaction()?;
        upsert_runtime(&transaction, runtime)?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    /// Persists a filesystem discovery without discarding a prior verification.
    ///
    /// Detection only proves where an executable currently resolves. When both
    /// paths are unchanged, the previous version/authentication result remains
    /// authoritative until the user explicitly verifies again. A new or moved
    /// executable intentionally falls back to the unverified detection state.
    #[allow(dead_code)]
    pub fn save_detected_runtime(&self, detected: &Runtime) -> StoreResult<Runtime> {
        self.save_detected_runtimes(std::slice::from_ref(detected))?
            .pop()
            .ok_or_else(|| StoreError::Invalid("runtime detection is empty".to_owned()))
    }

    /// Persists one complete runtime detection sweep in one transaction and
    /// advances the observable snapshot revision exactly once.
    pub fn save_detected_runtimes(&self, detected: &[Runtime]) -> StoreResult<Vec<Runtime>> {
        if detected.is_empty() {
            return Ok(Vec::new());
        }
        let transaction = self.connection.unchecked_transaction()?;
        let mut persisted = Vec::with_capacity(detected.len());
        for detected_runtime in detected {
            let runtime = match runtime_from_connection(&transaction, detected_runtime.kind)? {
                Some(previous)
                    if previous.launch_path == detected_runtime.launch_path
                        && previous.resolved_path == detected_runtime.resolved_path =>
                {
                    Runtime {
                        capabilities: detected_runtime.capabilities.clone(),
                        provider_engine: detected_runtime.provider_engine.clone(),
                        detected_at: detected_runtime.detected_at.clone(),
                        ..previous
                    }
                }
                _ => detected_runtime.clone(),
            };
            upsert_runtime(&transaction, &runtime)?;
            persisted.push(runtime);
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(persisted)
    }

    pub fn runtime(&self, kind: RuntimeKind) -> StoreResult<Option<Runtime>> {
        runtime_from_connection(&self.connection, kind)
    }

    pub fn runtimes(&self) -> StoreResult<Vec<Runtime>> {
        let mut statement = self.connection.prepare(
            "SELECT kind,launch_path,resolved_path,version,status,auth_status,capabilities,provider_engine,detected_at,verified_at,verify_error FROM runtime ORDER BY kind",
        )?;
        Ok(statement
            .query_map([], row_to_runtime)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    // Assistant persistence is deliberately separate from task_session: task sessions
    // track provider runtimes, while these records are the user-visible chat history.
    pub fn assistant_sessions(&self, include_archived: bool) -> StoreResult<Vec<AssistantSession>> {
        let filter = if include_archived {
            ""
        } else {
            "WHERE archived_at IS NULL"
        };
        let mut statement = self.connection.prepare(&format!(
            "SELECT s.id,s.title,s.created_at,s.updated_at,s.archived_at,
             coalesce((SELECT max(sequence) FROM chat_message m WHERE m.session_id=s.id),0),
             EXISTS(SELECT 1 FROM assistant_turn t WHERE t.session_id=s.id AND t.status IN ('queued','running'))
             FROM chat_session s {filter} ORDER BY s.updated_at DESC"
        ))?;
        Ok(statement
            .query_map([], row_to_assistant_session)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    pub fn assistant_session(&self, id: &str) -> StoreResult<Option<AssistantSession>> {
        let id = canonical_uuid(id, "sessionId")?;
        Ok(self
            .connection
            .query_row(
                "SELECT s.id,s.title,s.created_at,s.updated_at,s.archived_at,
                 coalesce((SELECT max(sequence) FROM chat_message m WHERE m.session_id=s.id),0),
                 EXISTS(SELECT 1 FROM assistant_turn t WHERE t.session_id=s.id AND t.status IN ('queued','running'))
                 FROM chat_session s WHERE s.id=?1",
                [&id],
                row_to_assistant_session,
            )
            .optional()?)
    }

    pub fn create_assistant_session(&self, title: &str) -> StoreResult<AssistantSession> {
        let timestamp = now();
        let title = if title.trim().is_empty() {
            "新对话"
        } else {
            title.trim()
        };
        validate_session_title(title)?;
        let session = AssistantSession {
            id: Uuid::new_v4().to_string(),
            title: title.to_owned(),
            created_at: timestamp.clone(),
            updated_at: timestamp,
            archived_at: None,
            last_sequence: 0,
            is_running: false,
        };
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO chat_session(id,title,created_at,updated_at) VALUES(?1,?2,?3,?4)",
            params![
                session.id,
                session.title,
                session.created_at,
                session.updated_at
            ],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(session)
    }

    pub fn rename_assistant_session(&self, id: &str, title: &str) -> StoreResult<AssistantSession> {
        let id = canonical_uuid(id, "sessionId")?;
        validate_session_title(title)?;
        let timestamp = now();
        let transaction = self.connection.unchecked_transaction()?;
        if transaction.execute(
            "UPDATE chat_session SET title=?1,updated_at=?2 WHERE id=?3",
            params![title.trim(), timestamp, id],
        )? == 0
        {
            return Err(StoreError::NotFound);
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.assistant_session(&id)?.ok_or(StoreError::NotFound)
    }

    pub fn archive_assistant_session(&self, id: &str) -> StoreResult<AssistantSession> {
        let id = canonical_uuid(id, "sessionId")?;
        let timestamp = now();
        let transaction = self.connection.unchecked_transaction()?;
        let active: Option<i64> = transaction.query_row(
            "SELECT 1 FROM assistant_turn WHERE session_id=?1 AND status IN ('queued','running')",
            [&id],
            |row| row.get(0),
        ).optional()?;
        if active.is_some() {
            return Err(StoreError::Conflict("assistant_session_busy"));
        }
        if transaction.execute(
            "UPDATE chat_session SET archived_at=coalesce(archived_at,?1),updated_at=?1 WHERE id=?2",
            params![timestamp, id],
        )? == 0 {
            return Err(StoreError::NotFound);
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.assistant_session(&id)?.ok_or(StoreError::NotFound)
    }

    pub fn begin_assistant_turn(
        &self,
        session_id: &str,
        client_message_id: &str,
        body: &str,
        task_refs_json: Option<&str>,
        model_id: Option<&str>,
    ) -> StoreResult<QueuedAssistantTurn> {
        self.begin_assistant_turn_with_payload(
            session_id,
            client_message_id,
            body,
            None,
            task_refs_json,
            model_id,
        )
    }

    pub fn begin_assistant_turn_with_payload(
        &self,
        session_id: &str,
        client_message_id: &str,
        body: &str,
        payload_json: Option<&str>,
        task_refs_json: Option<&str>,
        model_id: Option<&str>,
    ) -> StoreResult<QueuedAssistantTurn> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let client_message_id = canonical_uuid(client_message_id, "clientMessageId")?;
        if let Some((turn_id, existing_body, existing_payload, existing_model)) = self
            .connection
            .query_row(
                "SELECT m.turn_id,m.body,m.payload_json,t.model_id
             FROM chat_message m JOIN assistant_turn t ON t.id=m.turn_id
             WHERE m.session_id=?1 AND m.client_message_id=?2 AND m.turn_id IS NOT NULL",
                params![session_id, client_message_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                    ))
                },
            )
            .optional()?
        {
            if existing_body != body
                || existing_payload.as_deref() != payload_json
                || existing_model.as_deref() != model_id
            {
                return Err(StoreError::Conflict(
                    "assistant_client_message_payload_mismatch",
                ));
            }
            return Ok(QueuedAssistantTurn {
                session: self
                    .assistant_session(&session_id)?
                    .ok_or(StoreError::NotFound)?,
                turn: self.assistant_turn(&turn_id)?.ok_or(StoreError::NotFound)?,
                message: self
                    .assistant_message_for_client_id(&session_id, &client_message_id)?
                    .ok_or(StoreError::NotFound)?,
                is_new: false,
            });
        }
        let session = self
            .assistant_session(&session_id)?
            .ok_or(StoreError::NotFound)?;
        if session.archived_at.is_some() {
            return Err(StoreError::Conflict("assistant_session_archived"));
        }
        let active: Option<i64> = self.connection.query_row(
            "SELECT 1 FROM assistant_turn WHERE session_id=?1 AND status IN ('queued','running')",
            [&session_id],
            |row| row.get(0),
        ).optional()?;
        if active.is_some() {
            return Err(StoreError::Conflict("assistant_session_busy"));
        }
        let timestamp = now();
        let message_id = Uuid::new_v4().to_string();
        let turn_id = Uuid::new_v4().to_string();
        let transaction = self.connection.unchecked_transaction()?;
        let ordinal: i64 = transaction.query_row(
            "SELECT coalesce(max(ordinal),0)+1 FROM assistant_turn WHERE session_id=?1",
            [&session_id],
            |row| row.get(0),
        )?;
        let sequence = next_assistant_message_sequence(&transaction, &session_id)?;
        transaction.execute(
            "INSERT INTO chat_message(id,session_id,sequence,client_message_id,role,kind,body,payload_json,task_refs_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,'user','text',?5,?6,?7,?8,?8)",
            params![message_id, session_id, sequence, client_message_id, body, payload_json, task_refs_json, timestamp],
        )?;
        transaction.execute(
            "INSERT INTO assistant_turn(id,session_id,ordinal,user_message_id,model_id,status,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,'queued',?6,?6)",
            params![turn_id, session_id, ordinal, message_id, model_id, timestamp],
        )?;
        transaction.execute(
            "UPDATE chat_message SET turn_id=?1 WHERE id=?2",
            params![turn_id, message_id],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(QueuedAssistantTurn {
            session: self
                .assistant_session(&session_id)?
                .ok_or(StoreError::NotFound)?,
            turn: self.assistant_turn(&turn_id)?.ok_or(StoreError::NotFound)?,
            message: self
                .assistant_message(&message_id)?
                .ok_or(StoreError::NotFound)?,
            is_new: true,
        })
    }

    pub fn mark_assistant_turn_running(&self, turn_id: &str) -> StoreResult<AssistantTurn> {
        let timestamp = now();
        let transaction = self.connection.unchecked_transaction()?;
        let session_id: String = transaction
            .query_row(
                "SELECT session_id FROM assistant_turn WHERE id=?1 AND status='queued'",
                [turn_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        transaction.execute(
            "UPDATE assistant_turn SET status='running',attempt_count=attempt_count+1,started_at=?1,updated_at=?1 WHERE id=?2",
            params![timestamp, turn_id],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        let turn = assistant_turn_connection(&transaction, turn_id)?.ok_or(StoreError::NotFound)?;
        transaction.commit()?;
        Ok(turn)
    }

    #[allow(dead_code)]
    pub fn finish_assistant_turn(
        &self,
        turn_id: &str,
        status: AssistantTurnStatus,
        final_output: Option<&str>,
        error_code: Option<&str>,
        error_message: Option<&str>,
        usage_json: Option<&str>,
    ) -> StoreResult<AssistantTurn> {
        let timestamp = now();
        let transaction = self.connection.unchecked_transaction()?;
        let (session_id, current_status): (String, String) = transaction
            .query_row(
                "SELECT session_id,status FROM assistant_turn WHERE id=?1",
                [turn_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        let current_status = AssistantTurnStatus::parse(&current_status)
            .ok_or_else(|| StoreError::Invalid("invalid assistant turn status".to_owned()))?;
        if !matches!(
            current_status,
            AssistantTurnStatus::Queued | AssistantTurnStatus::Running
        ) && current_status != status
        {
            return Err(StoreError::Conflict("assistant_turn_already_finished"));
        }
        let (repair_code, repair_message) = assistant_terminal_repair_reason(status);
        repair_missing_assistant_function_results(
            &transaction,
            &session_id,
            turn_id,
            &timestamp,
            repair_code,
            repair_message,
        )?;
        let final_output =
            final_output.map(|value| bounded_utf8(value, SESSION_TIMELINE_TEXT_MAX_BYTES));
        let error_message =
            error_message.map(|value| bounded_utf8(value, SESSION_TIMELINE_PAYLOAD_MAX_BYTES));
        transaction.execute(
            "UPDATE assistant_turn SET status=?1,final_output=coalesce(?2,final_output),
             error_code=coalesce(?3,error_code),error_message=coalesce(?4,error_message),
             usage_json=coalesce(?5,usage_json),ended_at=coalesce(ended_at,?6),updated_at=?6 WHERE id=?7",
            params![status.as_str(), final_output.as_deref(), error_code, error_message.as_deref(), usage_json, timestamp, turn_id],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        let turn = assistant_turn_connection(&transaction, turn_id)?.ok_or(StoreError::NotFound)?;
        transaction.commit()?;
        Ok(turn)
    }

    /// Atomically terminalizes a non-successful turn and optionally appends one
    /// visible system message. The queued/running CAS races safely against the
    /// successful final-message transaction.
    #[allow(clippy::too_many_arguments)]
    pub fn finish_assistant_turn_with_message(
        &self,
        session_id: &str,
        turn_id: &str,
        status: AssistantTurnStatus,
        visible_message: Option<(&str, &str)>,
        final_output: Option<&str>,
        error_code: Option<&str>,
        error_message: Option<&str>,
        usage_json: Option<&str>,
    ) -> StoreResult<(Option<AssistantMessage>, AssistantTurn)> {
        if matches!(
            status,
            AssistantTurnStatus::Queued
                | AssistantTurnStatus::Running
                | AssistantTurnStatus::Completed
        ) {
            return Err(StoreError::Invalid(
                "terminal assistant status must be failed, cancelled, or interrupted".to_owned(),
            ));
        }
        if visible_message.is_some_and(|(kind, _)| !matches!(kind, "status" | "error")) {
            return Err(StoreError::Invalid(
                "terminal assistant message kind must be status or error".to_owned(),
            ));
        }
        let transaction = self.connection.unchecked_transaction()?;
        let current: Option<String> = transaction
            .query_row(
                "SELECT status FROM assistant_turn WHERE id=?1 AND session_id=?2",
                params![turn_id, session_id],
                |row| row.get(0),
            )
            .optional()?;
        let current = current.ok_or(StoreError::NotFound)?;
        let current = AssistantTurnStatus::parse(&current)
            .ok_or_else(|| StoreError::Invalid("invalid assistant turn status".to_owned()))?;
        if !matches!(
            current,
            AssistantTurnStatus::Queued | AssistantTurnStatus::Running
        ) {
            if current == status {
                let turn = assistant_turn_connection(&transaction, turn_id)?
                    .ok_or(StoreError::NotFound)?;
                transaction.commit()?;
                return Ok((None, turn));
            }
            return Err(StoreError::Conflict("assistant_turn_already_finished"));
        }
        let timestamp = now();
        let (repair_code, repair_message) = assistant_terminal_repair_reason(status);
        repair_missing_assistant_function_results(
            &transaction,
            session_id,
            turn_id,
            &timestamp,
            repair_code,
            repair_message,
        )?;
        let message_id = if let Some((kind, body)) = visible_message {
            let id = Uuid::new_v4().to_string();
            let sequence = next_assistant_message_sequence(&transaction, session_id)?;
            let (body, payload_json) = bounded_assistant_message_body("system", kind, body, None);
            transaction.execute(
                "INSERT INTO chat_message(id,session_id,turn_id,sequence,role,kind,body,payload_json,created_at,updated_at)
                 VALUES(?1,?2,?3,?4,'system',?5,?6,?7,?8,?8)",
                params![id, session_id, turn_id, sequence, kind, body, payload_json.as_deref(), timestamp],
            )?;
            Some(id)
        } else {
            None
        };
        let final_output =
            final_output.map(|value| bounded_utf8(value, SESSION_TIMELINE_TEXT_MAX_BYTES));
        let error_message =
            error_message.map(|value| bounded_utf8(value, SESSION_TIMELINE_PAYLOAD_MAX_BYTES));
        transaction.execute(
            "UPDATE assistant_turn SET status=?1,final_output=?2,error_code=?3,error_message=?4,
             usage_json=?5,ended_at=?6,updated_at=?6 WHERE id=?7",
            params![
                status.as_str(),
                final_output.as_deref(),
                error_code,
                error_message.as_deref(),
                usage_json,
                timestamp,
                turn_id
            ],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        let message = message_id
            .as_deref()
            .map(|id| assistant_message_connection(&transaction, id))
            .transpose()?
            .flatten();
        let turn = assistant_turn_connection(&transaction, turn_id)?.ok_or(StoreError::NotFound)?;
        transaction.commit()?;
        Ok((message, turn))
    }

    /// Atomically commits the final visible assistant message and the completed
    /// turn state. This removes the crash/cancel window where a final answer was
    /// visible but the turn could still be overwritten as failed or cancelled.
    pub fn complete_assistant_turn_with_message(
        &self,
        session_id: &str,
        turn_id: &str,
        text: &str,
        task_refs_json: Option<&str>,
        usage_json: Option<&str>,
    ) -> StoreResult<(AssistantMessage, AssistantTurn)> {
        let transaction = self.connection.unchecked_transaction()?;
        let status: Option<String> = transaction
            .query_row(
                "SELECT status FROM assistant_turn WHERE id=?1 AND session_id=?2",
                params![turn_id, session_id],
                |row| row.get(0),
            )
            .optional()?;
        match status.as_deref() {
            None => return Err(StoreError::NotFound),
            Some("running") => {}
            Some(_) => return Err(StoreError::Conflict("assistant_turn_not_running")),
        }
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        repair_missing_assistant_function_results(
            &transaction,
            session_id,
            turn_id,
            &timestamp,
            "tool_result_missing",
            "模型结束前工具调用没有返回结果，TodoAgent 已将其安全终止。",
        )?;
        let (visible_text, text_metadata) =
            bounded_assistant_message_body("todoagent", "text", text, None);
        let sequence = next_assistant_message_sequence(&transaction, session_id)?;
        transaction.execute(
            "INSERT INTO chat_message(id,session_id,turn_id,sequence,role,kind,body,payload_json,task_refs_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,'todoagent','text',?5,?6,?7,?8,?8)",
            params![id, session_id, turn_id, sequence, visible_text, text_metadata.as_deref(), task_refs_json, timestamp],
        )?;
        transaction.execute(
            "UPDATE assistant_turn SET status='completed',final_output=?1,error_code=NULL,error_message=NULL,
             usage_json=?2,ended_at=?3,updated_at=?3 WHERE id=?4",
            params![visible_text, usage_json, timestamp, turn_id],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        let message =
            assistant_message_connection(&transaction, &id)?.ok_or(StoreError::NotFound)?;
        let turn = assistant_turn_connection(&transaction, turn_id)?.ok_or(StoreError::NotFound)?;
        transaction.commit()?;
        Ok((message, turn))
    }

    #[allow(dead_code, clippy::too_many_arguments)]
    pub fn append_assistant_message(
        &self,
        session_id: &str,
        turn_id: &str,
        role: &str,
        kind: &str,
        body: &str,
        payload_json: Option<&str>,
        task_refs_json: Option<&str>,
    ) -> StoreResult<AssistantMessage> {
        if !matches!(role, "user" | "todoagent" | "system" | "tool") {
            return Err(StoreError::Invalid(
                "invalid assistant message role".to_owned(),
            ));
        }
        if !matches!(
            kind,
            "text" | "tool_call" | "tool_result" | "status" | "error"
        ) {
            return Err(StoreError::Invalid(
                "invalid assistant message kind".to_owned(),
            ));
        }
        let transaction = self.connection.unchecked_transaction()?;
        let session_exists: Option<i64> = transaction
            .query_row(
                "SELECT 1 FROM chat_session WHERE id=?1",
                [session_id],
                |row| row.get(0),
            )
            .optional()?;
        if session_exists.is_none() {
            return Err(StoreError::NotFound);
        }
        let status: Option<String> = transaction
            .query_row(
                "SELECT status FROM assistant_turn WHERE id=?1 AND session_id=?2",
                params![turn_id, session_id],
                |row| row.get(0),
            )
            .optional()?;
        match status.as_deref() {
            None => return Err(StoreError::NotFound),
            Some("running") => {}
            Some(_) => return Err(StoreError::Conflict("assistant_turn_not_running")),
        }
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        let sequence = next_assistant_message_sequence(&transaction, session_id)?;
        let (body, payload_json) = bounded_assistant_message_body(role, kind, body, payload_json);
        transaction.execute(
            "INSERT INTO chat_message(id,session_id,turn_id,sequence,role,kind,body,payload_json,task_refs_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10)",
            params![id, session_id, turn_id, sequence, role, kind, body, payload_json.as_deref(), task_refs_json, timestamp],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.assistant_message(&id)?.ok_or(StoreError::NotFound)
    }

    #[allow(dead_code, clippy::too_many_arguments)]
    pub fn append_assistant_step(
        &self,
        turn_id: &str,
        kind: &str,
        status: &str,
        title: Option<&str>,
        payload_json: Option<&str>,
        interaction_ordinal: i64,
        provider_step_index: Option<i64>,
    ) -> StoreResult<AssistantStep> {
        if !matches!(
            status,
            "queued" | "running" | "completed" | "failed" | "cancelled"
        ) {
            return Err(StoreError::Invalid(
                "invalid assistant step status".to_owned(),
            ));
        }
        let transaction = self.connection.unchecked_transaction()?;
        let (session_id, turn_status): (String, String) = transaction
            .query_row(
                "SELECT session_id,status FROM assistant_turn WHERE id=?1",
                [turn_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        if turn_status != "running" {
            return Err(StoreError::Conflict("assistant_turn_not_running"));
        }
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        let sequence = next_assistant_step_sequence(&transaction, &session_id)?;
        let payload_json = bounded_assistant_step_payload(kind, payload_json);
        transaction.execute(
            "INSERT INTO assistant_step(id,session_id,turn_id,sequence,interaction_ordinal,provider_step_index,kind,status,title,payload_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?11)",
            params![id, session_id, turn_id, sequence, interaction_ordinal, provider_step_index, kind, status, title, payload_json.as_deref(), timestamp],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.assistant_step(&id)?.ok_or(StoreError::NotFound)
    }

    /// Persists all provider-completed steps from one interaction atomically. This
    /// prevents a restart from exposing a partial ReAct interaction.
    #[allow(clippy::type_complexity)]
    pub fn append_assistant_steps(
        &self,
        turn_id: &str,
        interaction_ordinal: i64,
        steps: &[(&str, Option<&str>, Option<&str>, Option<i64>)],
    ) -> StoreResult<Vec<AssistantStep>> {
        if interaction_ordinal < 1 || steps.is_empty() {
            return Err(StoreError::Invalid(
                "assistant step batch is empty or has an invalid interaction ordinal".to_owned(),
            ));
        }
        if steps.iter().any(|(kind, _, _, _)| kind.trim().is_empty()) {
            return Err(StoreError::Invalid(
                "assistant step kind is empty".to_owned(),
            ));
        }
        let transaction = self.connection.unchecked_transaction()?;
        let (session_id, turn_status): (String, String) = transaction
            .query_row(
                "SELECT session_id,status FROM assistant_turn WHERE id=?1",
                [turn_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        if turn_status != "running" {
            return Err(StoreError::Conflict("assistant_turn_not_running"));
        }
        let mut sequence = next_assistant_step_sequence(&transaction, &session_id)?;
        let timestamp = now();
        let ids = steps
            .iter()
            .map(|(kind, title, payload_json, provider_step_index)| {
                let id = Uuid::new_v4().to_string();
                let payload_json = bounded_assistant_step_payload(kind, *payload_json);
                transaction.execute(
                    "INSERT INTO assistant_step(id,session_id,turn_id,sequence,interaction_ordinal,provider_step_index,kind,status,title,payload_json,created_at,updated_at)
                     VALUES(?1,?2,?3,?4,?5,?6,?7,'completed',?8,?9,?10,?10)",
                    params![id, session_id, turn_id, sequence, interaction_ordinal, provider_step_index, kind, title, payload_json.as_deref(), timestamp],
                )?;
                sequence += 1;
                Ok::<_, rusqlite::Error>(id)
            })
            .collect::<Result<Vec<_>, _>>()?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        ids.iter()
            .map(|id| self.assistant_step(id)?.ok_or(StoreError::NotFound))
            .collect()
    }

    /// Executes one of TodoAgent's SQLite-backed tools and records its receipt in
    /// the *same transaction*. A repeated callId returns the original result without
    /// running the mutation again.
    pub fn execute_assistant_tool(
        &self,
        turn_id: &str,
        call_id: &str,
        name: &str,
        arguments_json: &str,
    ) -> StoreResult<AssistantToolResult> {
        if call_id.trim().is_empty() {
            return Err(StoreError::Invalid("tool callId is required".to_owned()));
        }
        let arguments: Value = serde_json::from_str(arguments_json)
            .map_err(|_| StoreError::Invalid("tool arguments must be JSON".to_owned()))?;
        let transaction = self.connection.unchecked_transaction()?;
        let (session_id, turn_status): (String, String) = transaction
            .query_row(
                "SELECT session_id,status FROM assistant_turn WHERE id=?1",
                [turn_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        if let Some(receipt) = transaction.query_row(
            "SELECT response_json,is_error,task_refs_json FROM assistant_tool_execution WHERE session_id=?1 AND call_id=?2",
            params![session_id, call_id],
            |row| Ok((row.get::<_, Option<String>>(0)?, row.get::<_, i64>(1)?, row.get::<_, Option<String>>(2)?)),
        ).optional()? {
            return Ok(AssistantToolResult {
                result_json: bounded_tool_result_text(
                    name,
                    receipt.0.as_deref().unwrap_or("null"),
                ),
                is_error: receipt.1 != 0,
                task_refs_json: receipt.2.unwrap_or_else(|| "[]".to_owned()),
            });
        }
        if turn_status != "running" {
            return Err(StoreError::Conflict("assistant_turn_not_running"));
        }

        let (result, task_refs, did_mutate) = execute_builtin_tool(&transaction, name, &arguments)?;
        let result_json = bounded_tool_result_json(name, &result);
        let stored_arguments_json = bounded_tool_request_json(name, arguments_json);
        let task_refs_json = task_refs.to_string();
        let timestamp = now();
        transaction.execute(
            "INSERT INTO assistant_tool_execution(id,session_id,turn_id,call_id,tool_name,request_json,response_json,task_refs_json,is_error,status,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,0,'completed',?9,?9)",
            params![Uuid::new_v4().to_string(), session_id, turn_id, call_id, name, stored_arguments_json, result_json, task_refs_json, timestamp],
        )?;
        if did_mutate {
            bump_task_data_revision(&transaction)?;
        }
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        // The receipt is observable state too; all tool calls advance the revision.
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(AssistantToolResult {
            result_json,
            is_error: false,
            task_refs_json,
        })
    }

    /// Commits the assistant's filesystem-prepared task deletion and its durable
    /// tool receipt atomically. The caller must first hard-link every managed
    /// attachment to its quarantine name, then pass the exact prepared attachment
    /// ID/path manifest. Rechecking that manifest here closes the gap in which
    /// another request could attach or replace a managed file between preparation
    /// and the cascading DELETE.
    pub fn execute_assistant_delete_task(
        &self,
        turn_id: &str,
        call_id: &str,
        task_id: &str,
        prepared_attachments: &[(String, String)],
        arguments_json: &str,
    ) -> StoreResult<AssistantDeleteTaskOutcome> {
        if call_id.trim().is_empty() {
            return Err(StoreError::Invalid("tool callId is required".to_owned()));
        }
        let task_id = canonical_uuid(task_id, "delete_task.taskId")?;
        let arguments: Value = serde_json::from_str(arguments_json)
            .map_err(|_| StoreError::Invalid("tool arguments must be JSON".to_owned()))?;
        let argument_task_id = assistant_delete_task_id(&arguments)?;
        if argument_task_id != task_id {
            return Err(StoreError::Invalid(
                "delete_task.taskId does not match the prepared task".to_owned(),
            ));
        }
        let mut prepared_attachments = prepared_attachments
            .iter()
            .map(|(id, relative_path)| {
                let id = canonical_uuid(id, "delete_task.attachmentId")?;
                let managed_name = managed_attachment_file_name(relative_path)?;
                validate_managed_attachment_name(&managed_name, &id)?;
                Ok((id, relative_path.clone()))
            })
            .collect::<StoreResult<Vec<_>>>()?;
        prepared_attachments.sort_unstable();
        if prepared_attachments
            .windows(2)
            .any(|pair| pair[0].0 == pair[1].0)
        {
            return Err(StoreError::Invalid(
                "delete_task prepared attachment IDs must be unique".to_owned(),
            ));
        }

        let transaction = self.connection.unchecked_transaction()?;
        let (session_id, turn_status): (String, String) = transaction
            .query_row(
                "SELECT session_id,status FROM assistant_turn WHERE id=?1",
                [turn_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        let existing = transaction
            .query_row(
                "SELECT tool_name,request_json,response_json,is_error,task_refs_json
                 FROM assistant_tool_execution WHERE session_id=?1 AND call_id=?2",
                params![session_id, call_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, Option<String>>(4)?,
                    ))
                },
            )
            .optional()?;
        if let Some((tool_name, request_json, response_json, is_error, task_refs_json)) = existing {
            let stored_task_id = request_json
                .as_deref()
                .and_then(|value| serde_json::from_str::<Value>(value).ok())
                .and_then(|value| assistant_delete_task_id(&value).ok());
            if tool_name != "delete_task" || stored_task_id.as_deref() != Some(task_id.as_str()) {
                return Err(StoreError::Conflict("assistant_tool_call_mismatch"));
            }
            return Ok(AssistantDeleteTaskOutcome::Replayed(AssistantToolResult {
                result_json: bounded_tool_result_text(
                    "delete_task",
                    response_json.as_deref().unwrap_or("null"),
                ),
                is_error: is_error != 0,
                task_refs_json: task_refs_json.unwrap_or_else(|| "[]".to_owned()),
            }));
        }
        if turn_status != "running" {
            return Err(StoreError::Conflict("assistant_turn_not_running"));
        }

        let task: Task = transaction
            .query_row(
                "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at
                 FROM task WHERE id=?1",
                [&task_id],
                row_to_task,
            )
            .optional()?
            .ok_or(StoreError::NotFound)?;
        ensure_task_session_inactive(&transaction, &task_id)?;
        let mut attachment_statement = transaction
            .prepare("SELECT id,relative_path FROM task_attachment WHERE task_id=?1 ORDER BY id")?;
        let mut current_attachments = attachment_statement
            .query_map([&task_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(attachment_statement);
        current_attachments.sort_unstable();
        if current_attachments != prepared_attachments {
            return Err(StoreError::Conflict("task_attachments_changed"));
        }

        let changed = transaction.execute("DELETE FROM task WHERE id=?1", [&task_id])?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        let (deleted_task, truncated) = bounded_task_projection(&task);
        let result_json = bounded_tool_result_json(
            "delete_task",
            &json!({
                "deletedTask": deleted_task,
                "truncated": truncated,
            }),
        );
        let task_refs_json = "[]".to_owned();
        let stored_arguments_json = bounded_tool_request_json("delete_task", arguments_json);
        let timestamp = now();
        transaction.execute(
            "INSERT INTO assistant_tool_execution(id,session_id,turn_id,call_id,tool_name,request_json,response_json,task_refs_json,is_error,status,created_at,updated_at)
             VALUES(?1,?2,?3,?4,'delete_task',?5,?6,?7,0,'completed',?8,?8)",
            params![
                Uuid::new_v4().to_string(),
                session_id,
                turn_id,
                call_id,
                stored_arguments_json,
                result_json,
                task_refs_json,
                timestamp
            ],
        )?;
        bump_task_data_revision(&transaction)?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(AssistantDeleteTaskOutcome::Applied(AssistantToolResult {
            result_json,
            is_error: false,
            task_refs_json,
        }))
    }

    pub fn assistant_tool_execution(
        &self,
        session_id: &str,
        call_id: &str,
    ) -> StoreResult<Option<AssistantToolExecution>> {
        let mut execution = self.connection.query_row(
            "SELECT id,session_id,turn_id,step_id,call_id,tool_name,request_json,response_json,task_refs_json,is_error,status,error_code,error_message,created_at,updated_at
             FROM assistant_tool_execution WHERE session_id=?1 AND call_id=?2",
            params![session_id, call_id],
            row_to_assistant_tool_execution,
        ).optional()?;
        if let Some(execution) = execution.as_mut() {
            if let Some(response) = execution.response_json.as_deref() {
                execution.response_json =
                    Some(bounded_tool_result_text(&execution.tool_name, response));
            }
        }
        Ok(execution)
    }

    /// Stores a tool receipt once. Repeating a provider call ID returns the original
    /// record, allowing callers to avoid executing a mutating tool twice after retry.
    #[allow(clippy::too_many_arguments)]
    pub fn save_assistant_tool_execution(
        &self,
        session_id: &str,
        turn_id: &str,
        step_id: Option<&str>,
        call_id: &str,
        tool_name: &str,
        request_json: &str,
        response_json: Option<&str>,
        is_error: bool,
        status: &str,
        error_code: Option<&str>,
        error_message: Option<&str>,
    ) -> StoreResult<AssistantToolExecution> {
        if call_id.trim().is_empty() || tool_name.trim().is_empty() {
            return Err(StoreError::Invalid(
                "tool callId and name are required".to_owned(),
            ));
        }
        if !matches!(status, "running" | "completed" | "failed") {
            return Err(StoreError::Invalid(
                "invalid tool execution status".to_owned(),
            ));
        }
        if let Some(execution) = self.assistant_tool_execution(session_id, call_id)? {
            return Ok(execution);
        }
        let transaction = self.connection.unchecked_transaction()?;
        let exists: Option<i64> = transaction
            .query_row(
                "SELECT 1 FROM chat_session WHERE id=?1",
                [session_id],
                |row| row.get(0),
            )
            .optional()?;
        if exists.is_none() {
            return Err(StoreError::NotFound);
        }
        let turn_status: Option<String> = transaction
            .query_row(
                "SELECT status FROM assistant_turn WHERE id=?1 AND session_id=?2",
                params![turn_id, session_id],
                |row| row.get(0),
            )
            .optional()?;
        match turn_status.as_deref() {
            None => return Err(StoreError::NotFound),
            Some("running") => {}
            Some(_) => return Err(StoreError::Conflict("assistant_turn_not_running")),
        }
        if let Some(step_id) = step_id {
            let matches_turn: Option<i64> = transaction
                .query_row(
                    "SELECT 1 FROM assistant_step WHERE id=?1 AND session_id=?2 AND turn_id=?3",
                    params![step_id, session_id, turn_id],
                    |row| row.get(0),
                )
                .optional()?;
            if matches_turn.is_none() {
                return Err(StoreError::NotFound);
            }
        }
        let response_json =
            response_json.map(|response| bounded_tool_result_text(tool_name, response));
        let request_json = bounded_tool_request_json(tool_name, request_json);
        let timestamp = now();
        let id = Uuid::new_v4().to_string();
        transaction.execute(
            "INSERT INTO assistant_tool_execution(id,session_id,turn_id,step_id,call_id,tool_name,request_json,response_json,is_error,status,error_code,error_message,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?13)",
            params![id, session_id, turn_id, step_id, call_id, tool_name, request_json, response_json.as_deref(), is_error, status, error_code, error_message, timestamp],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.assistant_tool_execution(session_id, call_id)?
            .ok_or(StoreError::NotFound)
    }

    pub fn assistant_compaction(
        &self,
        session_id: &str,
    ) -> StoreResult<Option<AssistantCompaction>> {
        Ok(self.connection.query_row(
            "SELECT session_id,through_sequence,summary,payload_json,created_at,updated_at FROM assistant_compaction WHERE session_id=?1",
            [session_id],
            row_to_assistant_compaction,
        ).optional()?)
    }

    pub fn save_assistant_compaction(
        &self,
        session_id: &str,
        through_sequence: i64,
        summary: &str,
        payload_json: Option<&str>,
    ) -> StoreResult<AssistantCompaction> {
        if through_sequence < 0 || summary.trim().is_empty() {
            return Err(StoreError::Invalid(
                "invalid assistant compaction".to_owned(),
            ));
        }
        let transaction = self.connection.unchecked_transaction()?;
        let exists: Option<i64> = transaction
            .query_row(
                "SELECT 1 FROM chat_session WHERE id=?1",
                [session_id],
                |row| row.get(0),
            )
            .optional()?;
        if exists.is_none() {
            return Err(StoreError::NotFound);
        }
        // Compaction covers provider steps, not the user-visible message stream.
        // Those two tables deliberately maintain independent per-session cursors:
        // otherwise hidden ReAct steps would look like missing chat messages to Swift.
        let step_high_water: i64 = transaction.query_row(
            "SELECT coalesce(max(sequence),0) FROM assistant_step WHERE session_id=?1",
            [session_id],
            |row| row.get(0),
        )?;
        if through_sequence > step_high_water {
            return Err(StoreError::Invalid(
                "assistant compaction exceeds step high-water mark".to_owned(),
            ));
        }
        let current_watermark: Option<i64> = transaction
            .query_row(
                "SELECT through_sequence FROM assistant_compaction WHERE session_id=?1",
                [session_id],
                |row| row.get(0),
            )
            .optional()?;
        if current_watermark.is_some_and(|current| through_sequence < current) {
            return Err(StoreError::Conflict("assistant_compaction_regression"));
        }
        if through_sequence > 0 {
            let (turn_id, turn_status): (String, String) = transaction
                .query_row(
                    "SELECT s.turn_id,t.status
                     FROM assistant_step s JOIN assistant_turn t ON t.id=s.turn_id
                     WHERE s.session_id=?1 AND s.sequence=?2",
                    params![session_id, through_sequence],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?
                .ok_or_else(|| {
                    StoreError::Invalid("assistant compaction watermark is missing".to_owned())
                })?;
            let last_turn_sequence: i64 = transaction.query_row(
                "SELECT max(sequence) FROM assistant_step WHERE turn_id=?1",
                [turn_id],
                |row| row.get(0),
            )?;
            if through_sequence != last_turn_sequence
                || matches!(turn_status.as_str(), "queued" | "running")
            {
                return Err(StoreError::Invalid(
                    "assistant compaction must end at a completed turn boundary".to_owned(),
                ));
            }
        }
        let timestamp = now();
        transaction.execute(
            "INSERT INTO assistant_compaction(session_id,through_sequence,summary,payload_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?5)
             ON CONFLICT(session_id) DO UPDATE SET through_sequence=excluded.through_sequence,summary=excluded.summary,payload_json=excluded.payload_json,updated_at=excluded.updated_at",
            params![session_id, through_sequence, summary, payload_json, timestamp],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.assistant_compaction(session_id)?
            .ok_or(StoreError::NotFound)
    }

    pub fn assistant_history(
        &self,
        session_id: &str,
        after_sequence: i64,
        limit: i64,
    ) -> StoreResult<AssistantHistory> {
        let session = self
            .assistant_session(session_id)?
            .ok_or(StoreError::NotFound)?;
        let compaction = self.assistant_compaction(session_id)?;
        let limit = limit.clamp(1, 2000);
        let mut messages_statement = self.connection.prepare(
            "SELECT id,session_id,turn_id,sequence,client_message_id,role,kind,body,payload_json,task_refs_json,created_at,updated_at
             FROM chat_message WHERE session_id=?1 AND sequence>?2 ORDER BY sequence LIMIT ?3",
        )?;
        let mut message_rows =
            messages_statement.query(params![session_id, after_sequence, limit])?;
        let messages = collect_bounded_assistant_message_rows(&mut message_rows)?;
        let active_turn = self.connection.query_row(
            "SELECT id,session_id,ordinal,user_message_id,model_id,attempt_count,status,final_output,usage_json,error_code,error_message,started_at,ended_at,created_at,updated_at
             FROM assistant_turn WHERE session_id=?1 AND status IN ('queued','running') ORDER BY ordinal DESC LIMIT 1",
            [session_id],
            row_to_assistant_turn,
        ).optional()?;
        let mut visible_turns = messages
            .iter()
            .filter_map(|message| message.turn_id.clone())
            .collect::<HashSet<_>>();
        if let Some(turn) = active_turn.as_ref() {
            visible_turns.insert(turn.id.clone());
        }
        let visible_turns = visible_turns.into_iter().collect::<Vec<_>>();
        let (steps, tools, turn_ordinals, mut detail_truncated) = if visible_turns.is_empty() {
            (Vec::new(), Vec::new(), HashMap::new(), false)
        } else {
            let placeholders = std::iter::repeat_n("?", visible_turns.len())
                .collect::<Vec<_>>()
                .join(",");
            let steps_sql = format!(
                "SELECT id,session_id,turn_id,sequence,interaction_ordinal,provider_step_index,kind,status,title,payload_json,created_at,updated_at
                 FROM assistant_step
                 WHERE session_id=? AND turn_id IN ({placeholders})
                 ORDER BY sequence"
            );
            let mut steps_statement = self.connection.prepare(&steps_sql)?;
            let arguments =
                std::iter::once(session_id).chain(visible_turns.iter().map(String::as_str));
            let mut step_rows = steps_statement.query(params_from_iter(arguments))?;
            let mut detail_scan_bytes = 0_usize;
            let mut detail_truncated = false;
            let mut steps = Vec::new();
            while let Some(row) = step_rows.next()? {
                let step = row_to_assistant_step(row)?;
                let step_bytes = serialized_wire_bytes(&step);
                if detail_scan_bytes.saturating_add(step_bytes)
                    > ASSISTANT_HISTORY_DETAIL_PAGE_MAX_BYTES
                {
                    detail_truncated = true;
                    break;
                }
                detail_scan_bytes = detail_scan_bytes.saturating_add(step_bytes);
                steps.push(step);
            }

            let tools_sql = format!(
                "SELECT id,session_id,turn_id,call_id,tool_name,task_refs_json,is_error,status,created_at,updated_at
                 FROM assistant_tool_execution
                 WHERE session_id=? AND turn_id IN ({placeholders})
                 ORDER BY created_at,id"
            );
            let mut tools_statement = self.connection.prepare(&tools_sql)?;
            let arguments =
                std::iter::once(session_id).chain(visible_turns.iter().map(String::as_str));
            let mut tool_rows = tools_statement.query(params_from_iter(arguments))?;
            let mut tools = Vec::new();
            while let Some(row) = tool_rows.next()? {
                let tool = row_to_assistant_tool_summary(row)?;
                let tool_bytes = serialized_wire_bytes(&tool);
                if detail_scan_bytes.saturating_add(tool_bytes)
                    > ASSISTANT_HISTORY_DETAIL_PAGE_MAX_BYTES
                {
                    detail_truncated = true;
                    break;
                }
                detail_scan_bytes = detail_scan_bytes.saturating_add(tool_bytes);
                tools.push(tool);
            }

            let turns_sql = format!(
                "SELECT id,ordinal FROM assistant_turn WHERE session_id=? AND id IN ({placeholders})"
            );
            let mut turns_statement = self.connection.prepare(&turns_sql)?;
            let arguments =
                std::iter::once(session_id).chain(visible_turns.iter().map(String::as_str));
            let turn_ordinals = turns_statement
                .query_map(params_from_iter(arguments), |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })?
                .collect::<Result<HashMap<_, _>, _>>()?;
            (steps, tools, turn_ordinals, detail_truncated)
        };
        let projected_timeline =
            project_assistant_timeline(&messages, &steps, &tools, &turn_ordinals);
        let detail_payload_budget = ASSISTANT_HISTORY_DETAIL_PAGE_MAX_BYTES
            .saturating_sub(ASSISTANT_HISTORY_PARTIAL_NOTICE_RESERVE_BYTES);
        // Swift treats a non-empty timeline as authoritative, so legacy messages
        // cannot recover a final answer that was trimmed out here. Reserve every
        // turn's user message, last assistant text, and terminal status/error
        // before admitting reasoning/tool details. The legacy tools array is
        // lowest priority and can never evict those essential transcript items.
        let essential_ids = assistant_history_essential_timeline_ids(&projected_timeline);
        let mut detail_response_bytes = projected_timeline
            .iter()
            .filter(|item| essential_ids.contains(&item.id))
            .map(serialized_wire_bytes)
            .fold(0_usize, usize::saturating_add);
        if detail_response_bytes > detail_payload_budget {
            detail_truncated = true;
        }
        let mut selected_ids = essential_ids.clone();
        for item in &projected_timeline {
            if selected_ids.contains(&item.id) {
                continue;
            }
            let item_bytes = serialized_wire_bytes(&item);
            if detail_response_bytes.saturating_add(item_bytes) > detail_payload_budget {
                detail_truncated = true;
                continue;
            }
            detail_response_bytes = detail_response_bytes.saturating_add(item_bytes);
            selected_ids.insert(item.id.clone());
        }
        let mut bounded_tools = Vec::new();
        for tool in tools {
            let tool_bytes = serialized_wire_bytes(&tool);
            if detail_response_bytes.saturating_add(tool_bytes) > detail_payload_budget {
                detail_truncated = true;
                continue;
            }
            detail_response_bytes = detail_response_bytes.saturating_add(tool_bytes);
            bounded_tools.push(tool);
        }
        let mut timeline = projected_timeline
            .into_iter()
            .filter(|item| selected_ids.contains(&item.id))
            .collect::<Vec<_>>();
        if detail_truncated {
            timeline.push(assistant_history_partial_notice(
                &session,
                active_turn.as_ref(),
                &timeline,
                after_sequence,
            ));
        }
        Ok(AssistantHistory {
            session,
            messages,
            tools: bounded_tools,
            timeline,
            active_turn,
            compaction,
        })
    }

    /// Loads the stateless provider context independently from the UI message
    /// cursor. All steps after the compaction watermark are returned, grouped by
    /// their complete logical turns rather than cut at an arbitrary row limit.
    /// The current queued/running turn's user message is included even before it
    /// has any provider steps.
    pub fn assistant_context_history(
        &self,
        session_id: &str,
    ) -> StoreResult<AssistantContextHistory> {
        if self.assistant_session(session_id)?.is_none() {
            return Err(StoreError::NotFound);
        }
        let compaction = self.assistant_compaction(session_id)?;
        let watermark = compaction
            .as_ref()
            .map(|value| value.through_sequence)
            .unwrap_or(0);
        let mut steps_statement = self.connection.prepare(
            "SELECT id,session_id,turn_id,sequence,interaction_ordinal,provider_step_index,kind,status,title,payload_json,created_at,updated_at
             FROM assistant_step WHERE session_id=?1 AND sequence>?2 ORDER BY sequence",
        )?;
        let steps = steps_statement
            .query_map(params![session_id, watermark], row_to_assistant_step)?
            .collect::<Result<Vec<_>, _>>()?;
        let mut messages_statement = self.connection.prepare(
            "SELECT m.id,m.session_id,m.turn_id,m.sequence,m.client_message_id,m.role,m.kind,m.body,m.payload_json,m.task_refs_json,m.created_at,m.updated_at
             FROM assistant_turn t
             JOIN chat_message m ON m.id=t.user_message_id
             WHERE t.session_id=?1 AND (
               t.status IN ('queued','running') OR
               EXISTS (
                 SELECT 1 FROM assistant_step s
                 WHERE s.turn_id=t.id AND s.sequence>?2
               )
             )
             ORDER BY t.ordinal",
        )?;
        let messages = messages_statement
            .query_map(params![session_id, watermark], row_to_assistant_message)?
            .collect::<Result<Vec<_>, _>>()?;
        let active_turn = self.connection.query_row(
            "SELECT id,session_id,ordinal,user_message_id,model_id,attempt_count,status,final_output,usage_json,error_code,error_message,started_at,ended_at,created_at,updated_at
             FROM assistant_turn WHERE session_id=?1 AND status IN ('queued','running') ORDER BY ordinal DESC LIMIT 1",
            [session_id],
            row_to_assistant_turn,
        ).optional()?;
        Ok(AssistantContextHistory {
            messages,
            steps,
            active_turn,
            compaction,
        })
    }

    pub fn assistant_turn(&self, id: &str) -> StoreResult<Option<AssistantTurn>> {
        assistant_turn_connection(&self.connection, id)
    }

    fn assistant_message(&self, id: &str) -> StoreResult<Option<AssistantMessage>> {
        assistant_message_connection(&self.connection, id)
    }

    pub fn assistant_final_message_for_turn(
        &self,
        turn_id: &str,
    ) -> StoreResult<Option<AssistantMessage>> {
        Ok(self
            .connection
            .query_row(
                "SELECT id,session_id,turn_id,sequence,client_message_id,role,kind,body,payload_json,task_refs_json,created_at,updated_at
                 FROM chat_message
                 WHERE turn_id=?1 AND role='todoagent' AND kind='text'
                 ORDER BY sequence DESC LIMIT 1",
                [turn_id],
                row_to_assistant_message,
            )
            .optional()?)
    }

    fn assistant_message_for_client_id(
        &self,
        session_id: &str,
        client_message_id: &str,
    ) -> StoreResult<Option<AssistantMessage>> {
        Ok(self.connection.query_row(
            "SELECT id,session_id,turn_id,sequence,client_message_id,role,kind,body,payload_json,task_refs_json,created_at,updated_at
             FROM chat_message WHERE session_id=?1 AND client_message_id=?2",
            params![session_id, client_message_id],
            row_to_assistant_message,
        ).optional()?)
    }

    fn assistant_step(&self, id: &str) -> StoreResult<Option<AssistantStep>> {
        Ok(self.connection.query_row(
            "SELECT id,session_id,turn_id,sequence,interaction_ordinal,provider_step_index,kind,status,title,payload_json,created_at,updated_at FROM assistant_step WHERE id=?1",
            [id],
            row_to_assistant_step,
        ).optional()?)
    }

    /// Returns an already-created session for an exact replay, rejects a
    /// conflicting configuration for the task, or returns `None` when a new
    /// session may be created. Engine performs this read before runtime
    /// validation so a lost successful response remains replayable even if the
    /// runtime later becomes unavailable.
    pub fn prepare_terminal_session_create(
        &self,
        task_id: &str,
        runtime_kind: RuntimeKind,
        working_directory: &str,
    ) -> StoreResult<Option<TerminalSession>> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        if let Some(existing) = self.terminal_session_for_task(&task_id)? {
            if existing.runtime_kind == runtime_kind
                && existing.working_directory == working_directory
            {
                return Ok(Some(existing));
            }
            return Err(StoreError::Conflict("terminal_session_exists"));
        }
        if self.task(&task_id)?.is_none() {
            return Err(StoreError::NotFound);
        }
        Ok(None)
    }

    pub fn create_terminal_session(
        &self,
        task_id: &str,
        runtime_kind: RuntimeKind,
        working_directory: &str,
    ) -> StoreResult<TerminalSession> {
        if let Some(existing) =
            self.prepare_terminal_session_create(task_id, runtime_kind, working_directory)?
        {
            return Ok(existing);
        }
        let task_id = canonical_uuid(task_id, "taskId")?;
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        let (provider_id, binding_state, binding_source) = if runtime_kind == RuntimeKind::Claude {
            (
                Some(id.as_str()),
                ProviderBindingState::Bound.as_str(),
                Some("preallocated"),
            )
        } else {
            (None, ProviderBindingState::Unbound.as_str(), None)
        };
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO terminal_session(
               id,task_id,runtime_kind,working_directory,provider_session_id,
               provider_binding_state,provider_binding_source,created_at,updated_at
             ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?8)",
            params![
                id,
                task_id,
                runtime_kind.as_str(),
                working_directory,
                provider_id,
                binding_state,
                binding_source,
                timestamp
            ],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.terminal_session(&id)?.ok_or(StoreError::NotFound)
    }

    /// Permanently rebinds an inactive Session to a replacement workspace.
    /// Provider identity and all historical Runs remain unchanged so the next
    /// launch resumes the exact same conversation in the user-selected path.
    pub fn rebind_terminal_session_workspace(
        &self,
        session_id: &str,
        working_directory: &str,
    ) -> StoreResult<TerminalSessionBundle> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let working_directory = Path::new(working_directory);
        if !working_directory.is_absolute() {
            return Err(StoreError::Invalid(
                "workingDirectory must be absolute".to_owned(),
            ));
        }
        let working_directory = working_directory
            .to_str()
            .ok_or_else(|| StoreError::Invalid("workingDirectory must be UTF-8".to_owned()))?;
        let session = self
            .terminal_session(&session_id)?
            .ok_or(StoreError::NotFound)?;
        if self.active_terminal_run(&session_id)?.is_some() {
            return Err(StoreError::Conflict("terminal_session_active"));
        }
        if session.working_directory == working_directory {
            return self.terminal_session_bundle(&session_id);
        }
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "UPDATE terminal_session SET working_directory=?1,last_error_code=NULL,
             last_error_message=NULL,updated_at=?2 WHERE id=?3",
            params![working_directory, now(), session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.terminal_session_bundle(&session_id)
    }

    pub fn prepare_terminal_run(
        &self,
        session_id: &str,
        run_id: &str,
    ) -> StoreResult<TerminalSessionBundle> {
        self.prepare_terminal_run_with_resume_readiness(session_id, run_id, true)
    }

    pub fn prepare_terminal_run_with_resume_readiness(
        &self,
        session_id: &str,
        run_id: &str,
        provider_session_is_resumable: bool,
    ) -> StoreResult<TerminalSessionBundle> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let run_id = canonical_uuid(run_id, "runId")?;
        if let Some(existing) = self.terminal_run(&run_id)? {
            if existing.session_id != session_id {
                return Err(StoreError::Conflict("terminal_run_id_reused"));
            }
            return self.terminal_session_bundle(&session_id);
        }
        let session = self
            .terminal_session(&session_id)?
            .ok_or(StoreError::NotFound)?;
        if self.active_terminal_run(&session_id)?.is_some() {
            return Err(StoreError::Conflict("terminal_session_active"));
        }
        let ordinal: i64 = self.connection.query_row(
            "SELECT coalesce(max(ordinal),0)+1 FROM terminal_run WHERE session_id=?1",
            [&session_id],
            |row| row.get(0),
        )?;
        let prior_started: bool = self.connection.query_row(
            "SELECT EXISTS(
               SELECT 1 FROM terminal_run
               WHERE session_id=?1 AND started_at IS NOT NULL
             )",
            [&session_id],
            |row| row.get::<_, i64>(0),
        )? != 0;
        if prior_started && session.provider_session_id.is_none() {
            return Err(StoreError::Conflict("provider_binding_required"));
        }
        if session.runtime_kind == RuntimeKind::Cursor && session.provider_session_id.is_none() {
            return Err(StoreError::Conflict("provider_session_unbound"));
        }
        let timestamp = now();
        let launch_mode = if session.provider_session_id.is_some()
            && prior_started
            && provider_session_is_resumable
        {
            TerminalLaunchMode::Resume
        } else {
            TerminalLaunchMode::Fresh
        };
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO terminal_run(id,session_id,ordinal,launch_mode,state,provider_session_id_at_launch,created_at)
             VALUES(?1,?2,?3,?4,'starting',?5,?6)",
            params![
                run_id,
                session_id,
                ordinal,
                launch_mode.as_str(),
                session.provider_session_id,
                timestamp
            ],
        )?;
        transaction.execute(
            "UPDATE terminal_session SET agent_status='unknown',last_error_code=NULL,
             last_error_message=NULL,updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.terminal_session_bundle(&session_id)
    }

    pub fn prepare_terminal_run_with_provider(
        &self,
        session_id: &str,
        run_id: &str,
        provider_session_id: &str,
        source: &str,
    ) -> StoreResult<TerminalSessionBundle> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let run_id = canonical_uuid(run_id, "runId")?;
        validate_provider_session_id(provider_session_id)?;
        validate_binding_source(source)?;
        if self.terminal_run(&run_id)?.is_some() {
            return Err(StoreError::Conflict("terminal_run_id_reused"));
        }
        let session = self
            .terminal_session(&session_id)?
            .ok_or(StoreError::NotFound)?;
        if self.active_terminal_run(&session_id)?.is_some() {
            return Err(StoreError::Conflict("terminal_session_active"));
        }
        if let Some(existing) = session.provider_session_id.as_deref()
            && existing != provider_session_id
        {
            return Err(StoreError::Conflict("provider_session_conflict"));
        }
        let ordinal: i64 = self.connection.query_row(
            "SELECT coalesce(max(ordinal),0)+1 FROM terminal_run WHERE session_id=?1",
            [&session_id],
            |row| row.get(0),
        )?;
        let timestamp = now();
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "UPDATE terminal_session SET provider_session_id=?1,provider_binding_state='bound',
             provider_binding_source=?2,agent_status='unknown',last_error_code=NULL,
             last_error_message=NULL,updated_at=?3 WHERE id=?4",
            params![provider_session_id, source, timestamp, session_id],
        )?;
        transaction.execute(
            "INSERT INTO terminal_run(id,session_id,ordinal,launch_mode,state,provider_session_id_at_launch,created_at)
             VALUES(?1,?2,?3,?4,'starting',?5,?6)",
            params![
                run_id,
                session_id,
                ordinal,
                if ordinal == 1 { "fresh" } else { "resume" },
                provider_session_id,
                timestamp
            ],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.terminal_session_bundle(&session_id)
    }

    pub fn latest_terminal_run(&self, session_id: &str) -> StoreResult<Option<TerminalRun>> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        Ok(self
            .connection
            .query_row(
                &terminal_run_select("WHERE session_id=?1 ORDER BY ordinal DESC LIMIT 1"),
                [&session_id],
                row_to_terminal_run,
            )
            .optional()?)
    }

    pub fn mark_terminal_run_started(
        &self,
        session_id: &str,
        run_id: &str,
    ) -> StoreResult<TerminalSessionBundle> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let run_id = canonical_uuid(run_id, "runId")?;
        let run = self.terminal_run(&run_id)?.ok_or(StoreError::NotFound)?;
        if run.session_id != session_id {
            return Err(StoreError::Conflict("terminal_run_id_reused"));
        }
        if run.started_at.is_some()
            && matches!(
                run.state,
                TerminalRunState::Running | TerminalRunState::Stopping
            )
        {
            return self.terminal_session_bundle(&session_id);
        }
        if run.state == TerminalRunState::Stopping && run.started_at.is_none() {
            let timestamp = now();
            let transaction = self.connection.unchecked_transaction()?;
            let changed = transaction.execute(
                "UPDATE terminal_run SET started_at=?1
                 WHERE id=?2 AND session_id=?3 AND state='stopping' AND started_at IS NULL",
                params![timestamp, run_id, session_id],
            )?;
            if changed == 0 {
                return Err(StoreError::Conflict("terminal_run_result_conflict"));
            }
            transaction.execute(
                "UPDATE terminal_session SET last_started_at=?1,updated_at=?1 WHERE id=?2",
                params![timestamp, session_id],
            )?;
            bump_revision(&transaction)?;
            transaction.commit()?;
            return self.terminal_session_bundle(&session_id);
        }
        if run.state != TerminalRunState::Starting {
            return Err(StoreError::Conflict("terminal_run_result_conflict"));
        }
        self.transition_terminal_run(
            &session_id,
            &run_id,
            "starting",
            "running",
            None,
            None,
            None,
            None,
        )
    }

    pub fn mark_terminal_run_stopping(
        &self,
        session_id: &str,
        run_id: &str,
    ) -> StoreResult<TerminalSessionBundle> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let run_id = canonical_uuid(run_id, "runId")?;
        let run = self.terminal_run(&run_id)?.ok_or(StoreError::NotFound)?;
        if run.session_id != session_id {
            return Err(StoreError::Conflict("terminal_run_id_reused"));
        }
        if run.state == TerminalRunState::Stopping {
            return self.terminal_session_bundle(&session_id);
        }
        if !matches!(
            run.state,
            TerminalRunState::Starting | TerminalRunState::Running
        ) {
            return Err(StoreError::Conflict("terminal_run_result_conflict"));
        }
        let transaction = self.connection.unchecked_transaction()?;
        let changed = transaction.execute(
            "UPDATE terminal_run SET state='stopping'
             WHERE id=?1 AND session_id=?2 AND state IN ('starting','running')",
            params![run_id, session_id],
        )?;
        if changed == 0 {
            return Err(StoreError::Conflict("terminal_run_not_active"));
        }
        transaction.execute(
            "UPDATE terminal_session SET updated_at=?1 WHERE id=?2",
            params![now(), session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.terminal_session_bundle(&session_id)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn finish_terminal_run(
        &self,
        session_id: &str,
        run_id: &str,
        exit_code: Option<i32>,
        reason: &str,
        error_code: Option<&str>,
        error_message: Option<&str>,
    ) -> StoreResult<TerminalSessionBundle> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let run_id = canonical_uuid(run_id, "runId")?;
        if !matches!(
            reason,
            "process_exit" | "user_ended" | "app_shutdown" | "launch_failed"
        ) {
            return Err(StoreError::Invalid(
                "invalid terminal exit reason".to_owned(),
            ));
        }
        let state = if reason == "launch_failed" || error_code.is_some() {
            TerminalRunState::Failed
        } else {
            TerminalRunState::Exited
        };
        let run = self.terminal_run(&run_id)?.ok_or(StoreError::NotFound)?;
        if run.session_id != session_id {
            return Err(StoreError::Conflict("terminal_run_id_reused"));
        }
        if !run.state.is_active() {
            let exact_replay = run.state == state
                && run.exit_code == exit_code
                && run.exit_reason.as_deref() == Some(reason)
                && run.error_code.as_deref() == error_code
                && run.error_message.as_deref() == error_message;
            return if exact_replay {
                self.terminal_session_bundle(&session_id)
            } else {
                Err(StoreError::Conflict("terminal_run_result_conflict"))
            };
        }
        self.transition_terminal_run(
            &session_id,
            &run_id,
            "active",
            state.as_str(),
            exit_code,
            Some(reason),
            error_code,
            error_message,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn transition_terminal_run(
        &self,
        session_id: &str,
        run_id: &str,
        from: &str,
        to: &str,
        exit_code: Option<i32>,
        exit_reason: Option<&str>,
        error_code: Option<&str>,
        error_message: Option<&str>,
    ) -> StoreResult<TerminalSessionBundle> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let run_id = canonical_uuid(run_id, "runId")?;
        let timestamp = now();
        let predicate = if from == "active" {
            "state IN ('starting','running','stopping')"
        } else {
            "state='starting'"
        };
        let transaction = self.connection.unchecked_transaction()?;
        let changed = transaction.execute(
            &format!(
                "UPDATE terminal_run SET state=?1,exit_code=?2,exit_reason=?3,error_code=?4,
                 error_message=?5,started_at=CASE WHEN ?1='running' THEN ?6 ELSE started_at END,
                 exited_at=CASE WHEN ?1 IN ('exited','failed','interrupted') THEN ?6 ELSE exited_at END
                 WHERE id=?7 AND session_id=?8 AND {predicate}"
            ),
            params![
                to,
                exit_code,
                exit_reason,
                error_code,
                error_message,
                timestamp,
                run_id,
                session_id
            ],
        )?;
        if changed == 0 {
            return Err(StoreError::Conflict("terminal_run_not_active"));
        }
        transaction.execute(
            "UPDATE terminal_session SET
               last_started_at=CASE WHEN ?1='running' THEN ?2 ELSE last_started_at END,
               last_exited_at=CASE WHEN ?1 IN ('exited','failed','interrupted') THEN ?2 ELSE last_exited_at END,
               last_error_code=?3,last_error_message=?4,updated_at=?2 WHERE id=?5",
            params![to, timestamp, error_code, error_message, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.terminal_session_bundle(&session_id)
    }

    pub fn bind_terminal_provider(
        &self,
        session_id: &str,
        run_id: &str,
        provider_session_id: &str,
        source: &str,
    ) -> StoreResult<TerminalSessionBundle> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let run_id = canonical_uuid(run_id, "runId")?;
        validate_provider_session_id(provider_session_id)?;
        validate_binding_source(source)?;
        let run = self.terminal_run(&run_id)?.ok_or(StoreError::NotFound)?;
        let manual_latest = source == "manual"
            && self
                .connection
                .query_row(
                    "SELECT id=?1 FROM terminal_run WHERE session_id=?2 ORDER BY ordinal DESC LIMIT 1",
                    params![run_id, session_id],
                    |row| row.get::<_, bool>(0),
                )
                .optional()?
                .unwrap_or(false);
        if run.session_id != session_id || !(run.state.is_active() || manual_latest) {
            return Err(StoreError::Conflict("terminal_run_not_active"));
        }
        let session = self
            .terminal_session(&session_id)?
            .ok_or(StoreError::NotFound)?;
        if let Some(existing) = session.provider_session_id {
            if existing != provider_session_id {
                return Err(StoreError::Conflict("provider_session_conflict"));
            }
            return self.terminal_session_bundle(&session_id);
        }
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "UPDATE terminal_session SET provider_session_id=?1,provider_binding_state='bound',
             provider_binding_source=?2,updated_at=?3 WHERE id=?4 AND provider_session_id IS NULL",
            params![provider_session_id, source, now(), session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.terminal_session_bundle(&session_id)
    }

    pub fn report_terminal_status(
        &self,
        event_id: &str,
        session_id: &str,
        run_id: &str,
        status: TerminalAgentStatus,
    ) -> StoreResult<TerminalSessionBundle> {
        let event_id = canonical_uuid(event_id, "eventId")?;
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let run_id = canonical_uuid(run_id, "runId")?;
        if let Some((existing_session, existing_run, existing_status)) = self
            .connection
            .query_row(
                "SELECT session_id,run_id,status FROM terminal_status_receipt WHERE event_id=?1",
                [&event_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()?
        {
            if existing_session == session_id
                && existing_run == run_id
                && existing_status == status.as_str()
            {
                return self.terminal_session_bundle(&session_id);
            }
            return Err(StoreError::Conflict("terminal_status_event_id_reused"));
        }
        let run = self.terminal_run(&run_id)?.ok_or(StoreError::NotFound)?;
        if run.session_id != session_id || !run.state.is_active() {
            return Err(StoreError::Conflict("terminal_run_not_active"));
        }
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO terminal_status_receipt(event_id,session_id,run_id,status,created_at)
             VALUES(?1,?2,?3,?4,?5)",
            params![event_id, session_id, run_id, status.as_str(), now()],
        )?;
        transaction.execute(
            "UPDATE terminal_session SET agent_status=?1,
             status_sequence=status_sequence+CASE WHEN ?2 THEN 1 ELSE 0 END,
             updated_at=?3 WHERE id=?4",
            params![
                status.as_str(),
                status.creates_attention(),
                now(),
                session_id
            ],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.terminal_session_bundle(&session_id)
    }

    pub fn mark_terminal_seen(
        &self,
        session_id: &str,
        through: i64,
    ) -> StoreResult<TerminalSession> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let transaction = self.connection.unchecked_transaction()?;
        let changed = transaction.execute(
            "UPDATE terminal_session SET seen_status_sequence=min(max(seen_status_sequence,?1),status_sequence),
             updated_at=?2 WHERE id=?3",
            params![through.max(0), now(), session_id],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.terminal_session(&session_id)?
            .ok_or(StoreError::NotFound)
    }

    pub fn terminal_session_for_task(&self, task_id: &str) -> StoreResult<Option<TerminalSession>> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        Ok(self
            .connection
            .query_row(
                &terminal_session_select("WHERE task_id=?1"),
                [&task_id],
                row_to_terminal_session,
            )
            .optional()?)
    }

    pub fn terminal_session(&self, id: &str) -> StoreResult<Option<TerminalSession>> {
        let id = canonical_uuid(id, "sessionId")?;
        Ok(self
            .connection
            .query_row(
                &terminal_session_select("WHERE id=?1"),
                [&id],
                row_to_terminal_session,
            )
            .optional()?)
    }

    pub fn terminal_run(&self, id: &str) -> StoreResult<Option<TerminalRun>> {
        let id = canonical_uuid(id, "runId")?;
        Ok(self
            .connection
            .query_row(
                &terminal_run_select("WHERE id=?1"),
                [&id],
                row_to_terminal_run,
            )
            .optional()?)
    }

    pub fn active_terminal_run(&self, session_id: &str) -> StoreResult<Option<TerminalRun>> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        Ok(self
            .connection
            .query_row(
                &terminal_run_select(
                    "WHERE session_id=?1 AND state IN ('starting','running','stopping')",
                ),
                [&session_id],
                row_to_terminal_run,
            )
            .optional()?)
    }

    pub fn terminal_session_bundle(&self, session_id: &str) -> StoreResult<TerminalSessionBundle> {
        let session = self
            .terminal_session(session_id)?
            .ok_or(StoreError::NotFound)?;
        let active_run = match self.active_terminal_run(&session.id)? {
            Some(run) => Some(run),
            None => self.latest_terminal_run(&session.id)?,
        };
        Ok(TerminalSessionBundle {
            session,
            active_run,
        })
    }

    fn lists(&self) -> StoreResult<Vec<List>> {
        let mut statement = self.connection.prepare(
            "SELECT id,name,color,repository_path,archived_at,created_at,updated_at
             FROM list WHERE archived_at IS NULL ORDER BY created_at",
        )?;
        Ok(statement
            .query_map([], row_to_list)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    fn tasks(&self) -> StoreResult<Vec<Task>> {
        let mut statement = self.connection.prepare(
            "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at FROM task ORDER BY updated_at DESC",
        )?;
        Ok(statement
            .query_map([], row_to_task)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    fn task_attachments(&self) -> StoreResult<Vec<TaskAttachment>> {
        let mut statement = self.connection.prepare(
            "SELECT id,task_id,original_name,size_bytes,mime_type,relative_path,created_at
             FROM task_attachment ORDER BY created_at",
        )?;
        Ok(statement
            .query_map([], row_to_task_attachment)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    fn sessions(&self) -> StoreResult<Vec<TerminalSession>> {
        let mut statement = self
            .connection
            .prepare(&terminal_session_select("ORDER BY updated_at DESC"))?;
        Ok(statement
            .query_map([], row_to_terminal_session)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    fn reconcile_interrupted_terminal_runs(&self) -> StoreResult<()> {
        let transaction = self.connection.unchecked_transaction()?;
        let timestamp = now();
        let mut statement = transaction.prepare(
            "SELECT id,session_id FROM terminal_run WHERE state IN ('starting','running','stopping')",
        )?;
        let interrupted = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        for (run_id, session_id) in &interrupted {
            transaction.execute(
                "UPDATE terminal_run SET state='interrupted',error_code='engine_interrupted',
                 error_message='TodoAgent exited while this terminal was active',exited_at=?1 WHERE id=?2",
                params![timestamp, run_id],
            )?;
            transaction.execute(
                "UPDATE terminal_session SET agent_status='unknown',last_error_code='engine_interrupted',
                 last_error_message='TodoAgent exited while this terminal was active',last_exited_at=?1,
                 updated_at=?1 WHERE id=?2",
                params![timestamp, session_id],
            )?;
        }
        if !interrupted.is_empty() {
            bump_revision(&transaction)?;
        }
        transaction.commit()?;
        Ok(())
    }

    fn reconcile_interrupted_assistant_turns(&self) -> StoreResult<()> {
        let transaction = self.connection.unchecked_transaction()?;
        let timestamp = now();
        let mut statement = transaction.prepare(
            "SELECT id,session_id FROM assistant_turn WHERE status IN ('queued','running')",
        )?;
        let interrupted = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        for (turn_id, session_id) in &interrupted {
            repair_missing_assistant_function_results(
                &transaction,
                session_id,
                turn_id,
                &timestamp,
                "engine_interrupted",
                "TodoAgent 上次退出时该工具尚未完成，已安全终止且不会自动重试。",
            )?;
            transaction.execute(
                "UPDATE assistant_turn SET status='interrupted',error_code='engine_interrupted',
                 error_message='TodoAgent 上次退出时本轮仍在运行',ended_at=?1,updated_at=?1 WHERE id=?2",
                params![timestamp, turn_id],
            )?;
            let sequence = next_assistant_message_sequence(&transaction, session_id)?;
            transaction.execute(
                "INSERT INTO chat_message(id,session_id,turn_id,sequence,role,kind,body,created_at,updated_at)
                 VALUES(?1,?2,?3,?4,'system','error','TodoAgent 上次退出时本轮仍在运行，请重新发送消息继续。',?5,?5)",
                params![Uuid::new_v4().to_string(), session_id, turn_id, sequence, timestamp],
            )?;
            transaction.execute(
                "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
                params![timestamp, session_id],
            )?;
        }
        if !interrupted.is_empty() {
            bump_revision(&transaction)?;
        }
        transaction.commit()?;
        Ok(())
    }

    fn repair_terminal_assistant_turns(&self) -> StoreResult<()> {
        let transaction = self.connection.unchecked_transaction()?;
        let timestamp = now();
        let mut statement = transaction.prepare(
            "SELECT DISTINCT t.id,t.session_id,t.status
             FROM assistant_turn t
             JOIN assistant_step call
               ON call.turn_id=t.id
              AND call.kind='function_call'
              AND json_valid(call.payload_json)
             WHERE t.status IN ('completed','failed','cancelled','interrupted')
               AND NOT EXISTS (
                 SELECT 1 FROM assistant_step result
                 WHERE result.turn_id=t.id
                   AND result.kind='function_result'
                   AND json_valid(result.payload_json)
                   AND json_extract(result.payload_json,'$.call_id') =
                       json_extract(call.payload_json,'$.id')
               )",
        )?;
        let turns = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        drop(statement);
        let mut repaired = 0usize;
        let mut changed_sessions = HashSet::new();
        for (turn_id, session_id, raw_status) in turns {
            let Some(status) = AssistantTurnStatus::parse(&raw_status) else {
                continue;
            };
            let (code, message) = assistant_terminal_repair_reason(status);
            let count = repair_missing_assistant_function_results(
                &transaction,
                &session_id,
                &turn_id,
                &timestamp,
                code,
                message,
            )?;
            if count > 0 {
                repaired += count;
                changed_sessions.insert(session_id);
            }
        }
        if repaired > 0 {
            for session_id in changed_sessions {
                transaction.execute(
                    "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
                    params![timestamp, session_id],
                )?;
            }
            bump_revision(&transaction)?;
        }
        transaction.commit()?;
        Ok(())
    }
}

/// Performs only non-destructive preflight. v4 is migrated by `Store::open`;
/// unsupported legacy and future schemas are preserved and rejected.
pub fn prepare_database_files(database: &Path, attachments: &Path) -> StoreResult<()> {
    if !database.exists() {
        ensure_real_directory(attachments)?;
        remove_file_if_present(&sqlite_sidecar_path(database, "-wal"))?;
        remove_file_if_present(&sqlite_sidecar_path(database, "-shm"))?;
        return Ok(());
    }
    let connection = Connection::open(database)?;
    let version = database_schema_version(&connection)?;
    drop(connection);
    if version.is_some_and(|version| version > SCHEMA_VERSION) {
        return Err(StoreError::Invalid(format!(
            "database schema version {} is newer than supported version {SCHEMA_VERSION}",
            version.unwrap_or_default()
        )));
    }
    if matches!(version, Some(4 | SCHEMA_VERSION)) {
        return Ok(());
    }
    Err(StoreError::Invalid(format!(
        "database schema version {} cannot be upgraded directly; the original database was preserved",
        version.map_or_else(|| "unknown".to_owned(), |value| value.to_string())
    )))
}

fn remove_file_if_present(path: &Path) -> StoreResult<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn ensure_real_directory(path: &Path) -> StoreResult<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
        Ok(_) => {
            return Err(StoreError::Invalid(
                "managed attachments root must be a real directory".to_owned(),
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir_all(path)?,
        Err(error) => return Err(error.into()),
    }
    let directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_DIRECTORY | nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
        .open(path)?;
    if !directory.metadata()?.is_dir() {
        return Err(StoreError::Invalid(
            "managed attachments root must be a real directory".to_owned(),
        ));
    }
    Ok(())
}

fn managed_attachment_file_name(relative_path: &str) -> StoreResult<OsString> {
    let mut components = Path::new(relative_path).components();
    let valid_root = matches!(
        components.next(),
        Some(Component::Normal(component)) if component == "Attachments"
    );
    let file_name = match components.next() {
        Some(Component::Normal(file_name)) if components.next().is_none() => {
            file_name.to_os_string()
        }
        _ => {
            return Err(StoreError::Invalid(
                "managed attachment path is invalid".to_owned(),
            ));
        }
    };
    if !valid_root {
        return Err(StoreError::Invalid(
            "managed attachment path is invalid".to_owned(),
        ));
    }
    Ok(file_name)
}

fn validate_managed_attachment_name(file_name: &OsString, attachment_id: &str) -> StoreResult<()> {
    let file_name = file_name
        .to_str()
        .ok_or_else(|| StoreError::Invalid("managed attachment name is invalid".to_owned()))?;
    let suffix = file_name
        .strip_prefix(attachment_id)
        .ok_or_else(|| StoreError::Invalid("managed attachment name is invalid".to_owned()))?;
    let valid = suffix.is_empty()
        || suffix.strip_prefix('.').is_some_and(|extension| {
            !extension.is_empty()
                && extension.len() <= 16
                && extension
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric())
        });
    if !valid {
        return Err(StoreError::Invalid(
            "managed attachment name is invalid".to_owned(),
        ));
    }
    Ok(())
}

fn sqlite_sidecar_path(database: &Path, suffix: &str) -> std::path::PathBuf {
    let mut path = database.as_os_str().to_owned();
    path.push(suffix);
    path.into()
}

fn migrate(connection: &Connection) -> StoreResult<()> {
    let version = database_schema_version(connection)?;
    if version.is_some_and(|version| version > SCHEMA_VERSION) {
        return Err(StoreError::Invalid(format!(
            "database schema version {} is newer than supported version {SCHEMA_VERSION}",
            version.unwrap_or_default()
        )));
    }
    if version == Some(4) {
        create_v4_backup(connection)?;
        migrate_v4_to_v5(connection)?;
    } else if version.is_some_and(|version| version < 4)
        || (version.is_none() && has_application_tables(connection)?)
    {
        return Err(StoreError::Invalid(
            "legacy database cannot be upgraded directly; the original database was preserved"
                .to_owned(),
        ));
    }
    connection.execute_batch(include_str!("schema.sql"))?;
    connection.execute(
        "INSERT OR IGNORE INTO schema_migration(version,name,checksum,applied_at)
         VALUES(?1,'terminal sessions',?2,?3)",
        params![SCHEMA_VERSION, SCHEMA_CHECKSUM, now()],
    )?;
    let checksum: String = connection.query_row(
        "SELECT checksum FROM schema_migration WHERE version=?1",
        [SCHEMA_VERSION],
        |row| row.get(0),
    )?;
    if checksum != SCHEMA_CHECKSUM {
        return Err(StoreError::Invalid(
            "database schema v5 checksum does not match this Engine".to_owned(),
        ));
    }
    Ok(())
}

fn create_v4_backup(connection: &Connection) -> StoreResult<PathBuf> {
    use rusqlite::backup::Backup;

    connection.execute_batch("PRAGMA wal_checkpoint(FULL);")?;
    let source = connection
        .path()
        .ok_or_else(|| StoreError::Invalid("database path is unavailable".to_owned()))?;
    let source = Path::new(source);
    let parent = source
        .parent()
        .ok_or_else(|| StoreError::Invalid("database parent is unavailable".to_owned()))?;
    let file_name = source
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| StoreError::Invalid("database file name is invalid".to_owned()))?;
    let stamp = Utc::now().format("%Y%m%dT%H%M%S%.fZ");
    let backup_path = parent.join(format!("{file_name}.v4-backup-{stamp}"));
    let backup_file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
        .open(&backup_path)?;
    let metadata = backup_file.metadata()?;
    let uid = unsafe { nix::libc::geteuid() };
    if !metadata.is_file()
        || metadata.uid() != uid
        || metadata.nlink() != 1
        || metadata.permissions().mode() & 0o077 != 0
    {
        drop(backup_file);
        let _ = fs::remove_file(&backup_path);
        return Err(StoreError::Invalid(
            "v4 backup must be a current-user unlinked mode 0600 file".to_owned(),
        ));
    }
    drop(backup_file);
    let mut destination = Connection::open(&backup_path)?;
    {
        let backup = Backup::new(connection, &mut destination)?;
        backup.run_to_completion(128, Duration::from_millis(5), None)?;
    }
    drop(destination);
    Ok(backup_path)
}

fn migrate_v4_to_v5(connection: &Connection) -> StoreResult<()> {
    let transaction = connection.unchecked_transaction()?;
    transaction.execute_batch("PRAGMA defer_foreign_keys=ON;")?;
    // The product intentionally drops only the old structured Agent history.
    // Tasks, managed attachments, runtimes, settings and Assistant chat tables
    // stay in the same database and transaction.
    transaction.execute_batch(
        "DROP TABLE IF EXISTS session_timeline_projection;
         DROP TABLE IF EXISTS session_timeline_item;
         DROP TABLE IF EXISTS turn_event;
         DROP TABLE IF EXISTS session_message;
         DROP TABLE IF EXISTS session_turn;
         DROP TABLE IF EXISTS task_session;",
    )?;
    transaction.execute_batch(
        "CREATE TABLE terminal_session (
           id TEXT PRIMARY KEY,
           task_id TEXT NOT NULL UNIQUE REFERENCES task(id) ON DELETE CASCADE,
           runtime_kind TEXT NOT NULL CHECK(runtime_kind IN ('codex','claude','cursor','kiro')),
           working_directory TEXT NOT NULL,
           provider_session_id TEXT CHECK(provider_session_id IS NULL OR length(provider_session_id) BETWEEN 1 AND 512),
           provider_binding_state TEXT NOT NULL DEFAULT 'unbound' CHECK(provider_binding_state IN ('unbound','bound','capture_failed')),
           provider_binding_source TEXT,
           agent_status TEXT NOT NULL DEFAULT 'unknown' CHECK(agent_status IN ('unknown','idle','active','blocked','completed')),
           status_sequence INTEGER NOT NULL DEFAULT 0 CHECK(status_sequence >= 0),
           seen_status_sequence INTEGER NOT NULL DEFAULT 0 CHECK(seen_status_sequence BETWEEN 0 AND status_sequence),
           last_error_code TEXT,last_error_message TEXT,last_started_at TEXT,last_exited_at TEXT,
           created_at TEXT NOT NULL,updated_at TEXT NOT NULL
         );
         CREATE TABLE terminal_run (
           id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL REFERENCES terminal_session(id) ON DELETE CASCADE,
           ordinal INTEGER NOT NULL CHECK(ordinal > 0),
           launch_mode TEXT NOT NULL CHECK(launch_mode IN ('fresh','resume')),
           state TEXT NOT NULL CHECK(state IN ('starting','running','stopping','exited','failed','interrupted')),
           provider_session_id_at_launch TEXT,exit_code INTEGER,exit_reason TEXT,error_code TEXT,error_message TEXT,
           started_at TEXT,exited_at TEXT,created_at TEXT NOT NULL,
           UNIQUE(session_id, ordinal)
         );
         CREATE UNIQUE INDEX idx_terminal_one_active_run ON terminal_run(session_id)
           WHERE state IN ('starting','running','stopping');
         CREATE INDEX idx_terminal_session_task ON terminal_session(task_id);
         CREATE INDEX idx_terminal_run_session ON terminal_run(session_id,ordinal);
         CREATE TABLE terminal_status_receipt (
           event_id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL REFERENCES terminal_session(id) ON DELETE CASCADE,
           run_id TEXT NOT NULL REFERENCES terminal_run(id) ON DELETE CASCADE,
           status TEXT NOT NULL CHECK(status IN ('unknown','idle','active','blocked','completed')),
           created_at TEXT NOT NULL
         );
         CREATE INDEX idx_terminal_status_receipt_run ON terminal_status_receipt(run_id);",
    )?;
    let foreign_key_violations: i64 =
        transaction.query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |row| {
            row.get(0)
        })?;
    if foreign_key_violations != 0 {
        return Err(StoreError::Invalid(
            "v5 migration failed foreign-key validation".to_owned(),
        ));
    }
    transaction.execute(
        "INSERT INTO schema_migration(version,name,checksum,applied_at)
         VALUES(?1,'terminal sessions',?2,?3)",
        params![SCHEMA_VERSION, SCHEMA_CHECKSUM, now()],
    )?;
    transaction.commit()?;
    Ok(())
}

fn database_schema_version(connection: &Connection) -> StoreResult<Option<i64>> {
    if !table_exists(connection, "schema_migration")? {
        return Ok(None);
    }
    Ok(
        connection.query_row("SELECT max(version) FROM schema_migration", [], |row| {
            row.get(0)
        })?,
    )
}

fn has_application_tables(connection: &Connection) -> rusqlite::Result<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%')",
        [],
        |row| row.get::<_, i64>(0),
    )? != 0)
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

fn bump_task_data_revision(transaction: &Transaction<'_>) -> rusqlite::Result<()> {
    transaction.execute(
        "UPDATE task_data_revision SET revision=revision+1 WHERE singleton=1",
        [],
    )?;
    Ok(())
}

fn bounded_utf8(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_owned();
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

fn merged_metadata_json(existing: Option<&str>, additions: Value) -> String {
    let mut metadata = existing
        .and_then(|value| serde_json::from_str::<Value>(value).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    if let Value::Object(additions) = additions {
        metadata.extend(additions);
    }
    Value::Object(metadata).to_string()
}

fn bounded_assistant_message_body(
    role: &str,
    kind: &str,
    body: &str,
    payload_json: Option<&str>,
) -> (String, Option<String>) {
    let maximum_bytes = if role == "todoagent" && kind == "text" {
        SESSION_TIMELINE_TEXT_MAX_BYTES
    } else if matches!(kind, "tool_call" | "tool_result" | "status" | "error") {
        SESSION_TIMELINE_PAYLOAD_MAX_BYTES
    } else {
        return (body.to_owned(), payload_json.map(str::to_owned));
    };
    if body.len() <= maximum_bytes {
        return (body.to_owned(), payload_json.map(str::to_owned));
    }
    let metadata = merged_metadata_json(
        payload_json,
        json!({
            "originalBytes": body.len(),
            "truncated": true,
        }),
    );
    (bounded_utf8(body, maximum_bytes), Some(metadata))
}

fn bounded_assistant_step_payload(kind: &str, payload_json: Option<&str>) -> Option<String> {
    let payload_json = payload_json?;
    let maximum_bytes = if kind == "model_output" {
        SESSION_TIMELINE_TEXT_MAX_BYTES
    } else {
        SESSION_TIMELINE_PAYLOAD_MAX_BYTES
    };
    if payload_json.len() <= maximum_bytes {
        return Some(payload_json.to_owned());
    }
    let original_bytes = payload_json.len();
    let payload = serde_json::from_str::<Value>(payload_json).unwrap_or(Value::Null);
    let visible = match kind {
        "model_output" => assistant_visible_content(payload.get("content")),
        "thought" => assistant_visible_content(payload.get("summary")),
        _ => String::new(),
    };
    if !visible.is_empty() {
        let mut visible_limit = visible.len().min(maximum_bytes.saturating_sub(512));
        loop {
            let visible = bounded_utf8(&visible, visible_limit);
            let candidate = if kind == "thought" {
                json!({
                    "type":"thought",
                    "summary":[{"type":"text","text":visible}],
                    "_todoagentTruncated":{"originalBytes":original_bytes,"truncated":true}
                })
            } else {
                json!({
                    "type":"model_output",
                    "content":[{"type":"text","text":visible}],
                    "_todoagentTruncated":{"originalBytes":original_bytes,"truncated":true}
                })
            }
            .to_string();
            if candidate.len() <= maximum_bytes || visible_limit == 0 {
                return Some(candidate);
            }
            visible_limit /= 2;
        }
    }
    let mut envelope = serde_json::Map::new();
    envelope.insert("type".to_owned(), Value::String(kind.to_owned()));
    for key in ["id", "call_id", "name"] {
        if let Some(value) = payload.get(key).cloned() {
            envelope.insert(key.to_owned(), value);
        }
    }
    envelope.insert(
        "_todoagentTruncated".to_owned(),
        json!({"originalBytes":original_bytes,"truncated":true}),
    );
    Some(Value::Object(envelope).to_string())
}

fn bounded_tool_request_json(tool_name: &str, request_json: &str) -> String {
    if request_json.len() <= SESSION_TIMELINE_PAYLOAD_MAX_BYTES {
        return request_json.to_owned();
    }
    let payload = serde_json::from_str::<Value>(request_json).unwrap_or(Value::Null);
    let mut envelope = serde_json::Map::new();
    for key in ["taskId", "id", "callId"] {
        if let Some(value) = payload.get(key).cloned() {
            envelope.insert(key.to_owned(), value);
        }
    }
    envelope.insert(
        "_todoagentTruncated".to_owned(),
        json!({
            "tool": tool_name,
            "originalBytes": request_json.len(),
            "truncated": true
        }),
    );
    Value::Object(envelope).to_string()
}

fn project_assistant_timeline(
    messages: &[AssistantMessage],
    steps: &[AssistantStep],
    tools: &[AssistantToolSummary],
    turn_ordinals: &HashMap<String, i64>,
) -> Vec<SessionTimelineItem> {
    let mut ordered_turns = turn_ordinals.iter().collect::<Vec<_>>();
    ordered_turns.sort_by_key(|(_, ordinal)| **ordinal);
    let tool_summaries = tools
        .iter()
        .filter_map(|tool| {
            tool.turn_id
                .as_ref()
                .map(|turn_id| ((turn_id.as_str(), tool.call_id.as_str()), tool))
        })
        .collect::<HashMap<_, _>>();
    let mut timeline = Vec::new();
    for message in messages.iter().filter(|message| message.turn_id.is_none()) {
        let (kind, is_error) = match (message.role.as_str(), message.kind.as_str()) {
            ("user", "text") => ("user", false),
            ("todoagent", "text") => ("assistant_text", false),
            ("system", "error") => ("error", true),
            ("system", "status") => ("status", false),
            _ => continue,
        };
        let body = bounded_utf8(&message.body, SESSION_TIMELINE_TEXT_MAX_BYTES);
        push_assistant_timeline_item(
            &mut timeline,
            format!("assistant-timeline-message-{}", message.id),
            &message.session_id,
            &format!("standalone-{}", message.id),
            0,
            message.sequence,
            kind,
            &body,
            None,
            None,
            None,
            is_error,
            None,
            None,
            "legacy",
            &message.created_at,
            &message.updated_at,
        );
    }
    for (turn_id, turn_ordinal) in ordered_turns {
        // Slot zero is reserved for the turn's user message even when a later
        // chat-message page does not include it. Provider part cursors therefore
        // remain stable across overlapping assistant.history pages.
        let mut item_ordinal = 1_i64;
        let mut turn_messages = messages
            .iter()
            .filter(|message| message.turn_id.as_deref() == Some(turn_id.as_str()))
            .collect::<Vec<_>>();
        turn_messages.sort_by_key(|message| message.sequence);
        for message in turn_messages
            .iter()
            .copied()
            .filter(|message| message.role == "user" && message.kind == "text")
        {
            push_assistant_timeline_item(
                &mut timeline,
                format!("assistant-timeline-message-{}", message.id),
                &message.session_id,
                turn_id,
                *turn_ordinal,
                0,
                "user",
                &message.body,
                None,
                None,
                None,
                false,
                None,
                None,
                "exact",
                &message.created_at,
                &message.updated_at,
            );
        }

        let mut turn_steps = steps
            .iter()
            .filter(|step| step.turn_id == *turn_id)
            .collect::<Vec<_>>();
        turn_steps.sort_by_key(|step| step.sequence);
        let mut tool_item_indices = HashMap::<String, usize>::new();
        let mut emitted_model_text = false;
        for step in turn_steps {
            let payload = step
                .payload_json
                .as_deref()
                .and_then(|value| serde_json::from_str::<Value>(value).ok())
                .unwrap_or(Value::Null);
            match step.kind.as_str() {
                "model_output" => {
                    let text = assistant_visible_content(payload.get("content"));
                    if text.is_empty() {
                        continue;
                    }
                    emitted_model_text = true;
                    let body = bounded_utf8(&text, SESSION_TIMELINE_TEXT_MAX_BYTES);
                    push_assistant_timeline_item(
                        &mut timeline,
                        format!("assistant-timeline-step-{}", step.id),
                        &step.session_id,
                        turn_id,
                        *turn_ordinal,
                        item_ordinal,
                        "assistant_text",
                        &body,
                        None,
                        None,
                        None,
                        false,
                        Some(step.sequence),
                        step.provider_step_index,
                        "exact",
                        &step.created_at,
                        &step.updated_at,
                    );
                    item_ordinal += 1;
                }
                "thought" => {
                    // Only the provider's explicit summary is eligible for the
                    // UI. Signature, encrypted thought and raw deltas remain in
                    // the private context payload.
                    let summary = assistant_visible_content(payload.get("summary"));
                    if summary.is_empty() {
                        continue;
                    }
                    let body = bounded_utf8(&summary, SESSION_TIMELINE_REASONING_MAX_BYTES);
                    push_assistant_timeline_item(
                        &mut timeline,
                        format!("assistant-timeline-step-{}", step.id),
                        &step.session_id,
                        turn_id,
                        *turn_ordinal,
                        item_ordinal,
                        "reasoning",
                        &body,
                        None,
                        None,
                        None,
                        false,
                        Some(step.sequence),
                        step.provider_step_index,
                        "exact",
                        &step.created_at,
                        &step.updated_at,
                    );
                    item_ordinal += 1;
                }
                "function_call" => {
                    let Some(call_id) = payload
                        .get("id")
                        .or_else(|| payload.get("call_id"))
                        .and_then(Value::as_str)
                        .filter(|value| !value.is_empty())
                    else {
                        continue;
                    };
                    let name = payload
                        .get("name")
                        .and_then(Value::as_str)
                        .or(step.title.as_deref())
                        .unwrap_or("tool");
                    let summary = tool_summaries.get(&(turn_id.as_str(), call_id));
                    let (tool_state, is_error) = summary.map_or(("running", false), |tool| {
                        (
                            assistant_tool_state(&tool.status, tool.is_error),
                            tool.is_error,
                        )
                    });
                    let index = timeline.len();
                    push_assistant_timeline_item(
                        &mut timeline,
                        format!("assistant-timeline-tool-{turn_id}-{call_id}"),
                        &step.session_id,
                        turn_id,
                        *turn_ordinal,
                        item_ordinal,
                        "tool",
                        "",
                        Some(call_id),
                        Some(name),
                        Some(tool_state),
                        is_error,
                        Some(step.sequence),
                        step.provider_step_index,
                        "exact",
                        &step.created_at,
                        summary.map_or(step.updated_at.as_str(), |tool| tool.updated_at.as_str()),
                    );
                    if let Some(arguments) = payload.get("arguments") {
                        let raw = if let Some(value) = arguments.as_str() {
                            value.to_owned()
                        } else {
                            arguments.to_string()
                        };
                        timeline[index].input_json =
                            Some(bounded_utf8(&raw, SESSION_TIMELINE_PAYLOAD_MAX_BYTES));
                        if raw.len() > SESSION_TIMELINE_PAYLOAD_MAX_BYTES {
                            timeline[index].metadata_json = Some(
                                json!({
                                    "inputOriginalBytes":raw.len(),
                                    "inputTruncated":true
                                })
                                .to_string(),
                            );
                        }
                    }
                    tool_item_indices.insert(call_id.to_owned(), index);
                    item_ordinal += 1;
                }
                "function_result" => {
                    let Some(call_id) = payload
                        .get("call_id")
                        .or_else(|| payload.get("id"))
                        .and_then(Value::as_str)
                        .filter(|value| !value.is_empty())
                    else {
                        continue;
                    };
                    let is_error = payload.get("is_error").and_then(Value::as_bool) == Some(true);
                    if let Some(index) = tool_item_indices.get(call_id).copied() {
                        let item = &mut timeline[index];
                        item.tool_state =
                            Some(if is_error { "failed" } else { "completed" }.to_owned());
                        item.is_error = is_error;
                        item.updated_at = step.updated_at.clone();
                        if let Some(result) = payload.get("result") {
                            let raw = if let Some(value) = result.as_str() {
                                value.to_owned()
                            } else {
                                result.to_string()
                            };
                            item.output_text =
                                Some(bounded_utf8(&raw, SESSION_TIMELINE_PAYLOAD_MAX_BYTES));
                            if raw.len() > SESSION_TIMELINE_PAYLOAD_MAX_BYTES {
                                let mut metadata = item
                                    .metadata_json
                                    .as_deref()
                                    .and_then(|value| serde_json::from_str::<Value>(value).ok())
                                    .and_then(|value| value.as_object().cloned())
                                    .unwrap_or_default();
                                metadata.insert("outputOriginalBytes".to_owned(), json!(raw.len()));
                                metadata.insert("outputTruncated".to_owned(), Value::Bool(true));
                                item.metadata_json = Some(Value::Object(metadata).to_string());
                            }
                        }
                    } else {
                        let name = payload
                            .get("name")
                            .and_then(Value::as_str)
                            .or(step.title.as_deref())
                            .unwrap_or("tool");
                        push_assistant_timeline_item(
                            &mut timeline,
                            format!("assistant-timeline-tool-{turn_id}-{call_id}"),
                            &step.session_id,
                            turn_id,
                            *turn_ordinal,
                            item_ordinal,
                            "tool",
                            "",
                            Some(call_id),
                            Some(name),
                            Some(if is_error { "failed" } else { "completed" }),
                            is_error,
                            Some(step.sequence),
                            step.provider_step_index,
                            "partial",
                            &step.created_at,
                            &step.updated_at,
                        );
                        let index = timeline.len() - 1;
                        if let Some(result) = payload.get("result") {
                            let raw = if let Some(value) = result.as_str() {
                                value.to_owned()
                            } else {
                                result.to_string()
                            };
                            timeline[index].output_text =
                                Some(bounded_utf8(&raw, SESSION_TIMELINE_PAYLOAD_MAX_BYTES));
                            if raw.len() > SESSION_TIMELINE_PAYLOAD_MAX_BYTES {
                                timeline[index].metadata_json = Some(
                                    json!({
                                        "outputOriginalBytes":raw.len(),
                                        "outputTruncated":true
                                    })
                                    .to_string(),
                                );
                            }
                        }
                        tool_item_indices.insert(call_id.to_owned(), index);
                        item_ordinal += 1;
                    }
                }
                _ => {}
            }
        }

        for tool in tools.iter().filter(|tool| {
            tool.turn_id.as_deref() == Some(turn_id.as_str())
                && !tool_item_indices.contains_key(&tool.call_id)
        }) {
            push_assistant_timeline_item(
                &mut timeline,
                format!("assistant-timeline-tool-{turn_id}-{}", tool.call_id),
                &tool.session_id,
                turn_id,
                *turn_ordinal,
                item_ordinal,
                "tool",
                "",
                Some(&tool.call_id),
                Some(&tool.tool_name),
                Some(assistant_tool_state(&tool.status, tool.is_error)),
                tool.is_error,
                None,
                None,
                "partial",
                &tool.created_at,
                &tool.updated_at,
            );
            item_ordinal += 1;
        }

        for message in turn_messages.into_iter().filter(|message| {
            (message.role == "todoagent" && message.kind == "text" && !emitted_model_text)
                || (message.role == "system" && matches!(message.kind.as_str(), "status" | "error"))
        }) {
            let kind = if message.role == "todoagent" {
                "assistant_text"
            } else if message.kind == "error" {
                "error"
            } else {
                "status"
            };
            let body = bounded_utf8(&message.body, SESSION_TIMELINE_TEXT_MAX_BYTES);
            push_assistant_timeline_item(
                &mut timeline,
                format!("assistant-timeline-message-{}", message.id),
                &message.session_id,
                turn_id,
                *turn_ordinal,
                item_ordinal,
                kind,
                &body,
                None,
                None,
                None,
                kind == "error",
                None,
                None,
                "legacy",
                &message.created_at,
                &message.updated_at,
            );
            item_ordinal += 1;
        }
    }
    timeline.sort_by_key(|item| (item.turn_ordinal, item.item_ordinal, item.id.clone()));
    timeline
}

fn assistant_visible_content(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(value)) => value.clone(),
        Some(Value::Array(values)) => values
            .iter()
            .map(|value| assistant_visible_content(Some(value)))
            .collect(),
        Some(Value::Object(value)) => {
            if value.get("type").and_then(Value::as_str) == Some("text") {
                return value
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
            }
            assistant_visible_content(value.get("content"))
        }
        Some(_) => String::new(),
    }
}

fn assistant_tool_state(status: &str, is_error: bool) -> &'static str {
    if is_error || status == "failed" {
        "failed"
    } else if status == "completed" {
        "completed"
    } else {
        "running"
    }
}

#[allow(clippy::too_many_arguments)]
fn push_assistant_timeline_item(
    timeline: &mut Vec<SessionTimelineItem>,
    id: String,
    session_id: &str,
    turn_id: &str,
    turn_ordinal: i64,
    item_ordinal: i64,
    kind: &str,
    body: &str,
    call_id: Option<&str>,
    tool_name: Option<&str>,
    tool_state: Option<&str>,
    is_error: bool,
    source_event_sequence: Option<i64>,
    source_block_index: Option<i64>,
    fidelity: &str,
    created_at: &str,
    updated_at: &str,
) {
    timeline.push(SessionTimelineItem {
        id,
        session_id: session_id.to_owned(),
        turn_id: turn_id.to_owned(),
        sequence: turn_ordinal
            .saturating_mul(1_000_000)
            .saturating_add(item_ordinal)
            .saturating_add(1),
        turn_ordinal,
        item_ordinal,
        kind: kind.to_owned(),
        body: body.to_owned(),
        call_id: call_id.map(str::to_owned),
        tool_name: tool_name.map(str::to_owned),
        input_json: None,
        output_text: None,
        tool_state: tool_state.map(str::to_owned),
        is_error,
        source_event_sequence,
        source_block_index,
        fidelity: fidelity.to_owned(),
        metadata_json: None,
        created_at: created_at.to_owned(),
        updated_at: updated_at.to_owned(),
    });
}

fn next_assistant_message_sequence(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> rusqlite::Result<i64> {
    transaction.query_row(
        "SELECT coalesce(max(sequence),0)+1 FROM chat_message WHERE session_id=?1",
        [session_id],
        |row| row.get(0),
    )
}

fn next_assistant_step_sequence(
    transaction: &Transaction<'_>,
    session_id: &str,
) -> rusqlite::Result<i64> {
    transaction.query_row(
        "SELECT coalesce(max(sequence),0)+1 FROM assistant_step WHERE session_id=?1",
        [session_id],
        |row| row.get(0),
    )
}

/// Closes every persisted function call before a turn becomes terminal.
///
/// A durable receipt is replayed without invoking the tool. Calls that never
/// obtained a receipt receive an explicit terminal error result, because their
/// SQLite side effects did not commit. This keeps stateless provider history
/// structurally valid across cancellation, failure, and process crashes.
fn repair_missing_assistant_function_results(
    transaction: &Transaction<'_>,
    session_id: &str,
    turn_id: &str,
    timestamp: &str,
    terminal_code: &str,
    terminal_message: &str,
) -> rusqlite::Result<usize> {
    let mut step_statement = transaction.prepare(
        "SELECT kind,payload_json FROM assistant_step WHERE turn_id=?1 ORDER BY sequence",
    )?;
    let payloads = step_statement
        .query_map([turn_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(step_statement);
    let mut calls = Vec::<(String, String)>::new();
    let mut seen_calls = HashSet::<String>::new();
    let mut results = HashSet::<String>::new();
    for (kind, payload) in payloads {
        let Some(payload) = payload
            .as_deref()
            .and_then(|payload| serde_json::from_str::<Value>(payload).ok())
        else {
            continue;
        };
        match kind.as_str() {
            "function_call" => {
                if let (Some(call_id), Some(name)) = (
                    payload.get("id").and_then(Value::as_str),
                    payload.get("name").and_then(Value::as_str),
                ) && seen_calls.insert(call_id.to_owned())
                {
                    calls.push((call_id.to_owned(), name.to_owned()));
                }
            }
            "function_result" => {
                if let Some(call_id) = payload.get("call_id").and_then(Value::as_str) {
                    results.insert(call_id.to_owned());
                }
            }
            _ => {}
        }
    }
    let mut receipt_statement = transaction.prepare(
        "SELECT call_id,tool_name,response_json,is_error
         FROM assistant_tool_execution
         WHERE session_id=?1 AND turn_id=?2 AND status IN ('completed','failed')
         ORDER BY created_at,id",
    )?;
    let receipts = receipt_statement
        .query_map(params![session_id, turn_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, i64>(3)? != 0,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?
        .into_iter()
        .map(|receipt| (receipt.0.clone(), receipt))
        .collect::<HashMap<_, _>>();
    drop(receipt_statement);
    let missing = calls
        .into_iter()
        .filter(|(call_id, _)| !results.contains(call_id))
        .collect::<Vec<_>>();
    if missing.is_empty() {
        return Ok(0);
    }
    let interaction_ordinal: i64 = transaction.query_row(
        "SELECT coalesce(max(interaction_ordinal),0)+1 FROM assistant_step WHERE turn_id=?1",
        [turn_id],
        |row| row.get(0),
    )?;
    let mut sequence = next_assistant_step_sequence(transaction, session_id)?;
    let repaired = missing.len();
    for (provider_step_index, (call_id, tool_name)) in missing.into_iter().enumerate() {
        let (result, is_error) = match receipts.get(&call_id) {
            Some((_, receipt_name, response, receipt_is_error)) if receipt_name == &tool_name => {
                let response =
                    bounded_tool_result_text(&tool_name, response.as_deref().unwrap_or("null"));
                (
                    serde_json::from_str::<Value>(&response).unwrap_or(Value::Null),
                    *receipt_is_error,
                )
            }
            _ => (
                json!({
                    "error": {
                        "code": terminal_code,
                        "message": terminal_message,
                    },
                    "executed": false,
                }),
                true,
            ),
        };
        let payload = json!({
            "type": "function_result",
            "call_id": call_id,
            "name": tool_name,
            "result": result,
            "is_error": is_error,
        })
        .to_string();
        transaction.execute(
            "INSERT INTO assistant_step(id,session_id,turn_id,sequence,interaction_ordinal,provider_step_index,kind,status,title,payload_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,'function_result','completed',?7,?8,?9,?9)",
            params![
                Uuid::new_v4().to_string(),
                session_id,
                turn_id,
                sequence,
                interaction_ordinal,
                provider_step_index as i64,
                tool_name,
                payload,
                timestamp,
            ],
        )?;
        sequence += 1;
    }
    Ok(repaired)
}

fn assistant_terminal_repair_reason(status: AssistantTurnStatus) -> (&'static str, &'static str) {
    match status {
        AssistantTurnStatus::Completed => (
            "tool_result_missing",
            "模型结束前工具调用没有返回结果，TodoAgent 已将其安全终止。",
        ),
        AssistantTurnStatus::Failed => (
            "turn_failed",
            "本轮失败时该工具尚未完成，已安全终止且不会自动重试。",
        ),
        AssistantTurnStatus::Cancelled => (
            "turn_cancelled",
            "本轮取消时该工具尚未完成，已安全终止且不会自动重试。",
        ),
        AssistantTurnStatus::Interrupted => (
            "engine_interrupted",
            "TodoAgent 退出时该工具尚未完成，已安全终止且不会自动重试。",
        ),
        AssistantTurnStatus::Queued | AssistantTurnStatus::Running => (
            "turn_ended",
            "本轮结束时该工具尚未完成，已安全终止且不会自动重试。",
        ),
    }
}

fn execute_builtin_tool(
    transaction: &Transaction<'_>,
    name: &str,
    arguments: &Value,
) -> StoreResult<(Value, Value, bool)> {
    match name {
        "create_tasks" => {
            let object = tool_arguments_object("create_tasks", arguments)?;
            ensure_only_fields("create_tasks", object, &["tasks"])?;
            let task_values = object
                .get("tasks")
                .ok_or_else(|| StoreError::Invalid("create_tasks.tasks is required".to_owned()))?
                .as_array()
                .ok_or_else(|| {
                    StoreError::Invalid("create_tasks.tasks must be an array".to_owned())
                })?;
            if !(1..=10).contains(&task_values.len()) {
                return Err(StoreError::Invalid(
                    "create_tasks accepts between 1 and 10 tasks".to_owned(),
                ));
            }
            for (index, task) in task_values.iter().enumerate() {
                let task = task.as_object().ok_or_else(|| {
                    StoreError::Invalid(format!("create_tasks.tasks[{index}] must be an object"))
                })?;
                ensure_only_fields(
                    &format!("create_tasks.tasks[{index}]"),
                    task,
                    &["title", "note", "listId", "executionDate", "dueDate"],
                )?;
                required_string_field(&format!("create_tasks.tasks[{index}]"), task, "title")?;
                optional_string_field(
                    &format!("create_tasks.tasks[{index}]"),
                    task,
                    "note",
                    false,
                )?;
                optional_string_field(
                    &format!("create_tasks.tasks[{index}]"),
                    task,
                    "listId",
                    false,
                )?;
                optional_string_field(
                    &format!("create_tasks.tasks[{index}]"),
                    task,
                    "executionDate",
                    false,
                )?;
                optional_string_field(
                    &format!("create_tasks.tasks[{index}]"),
                    task,
                    "dueDate",
                    false,
                )?;
            }
            let mut inputs: Vec<CreateTaskInput> =
                serde_json::from_value(Value::Array(task_values.clone())).map_err(|_| {
                    StoreError::Invalid("invalid create_tasks arguments".to_owned())
                })?;
            for input in &mut inputs {
                if let Some(list_id) = input.list_id.as_mut() {
                    *list_id = canonical_uuid(list_id, "create_tasks.tasks[].listId")?;
                }
                validate_task_input(input)?;
                if let Some(list_id) = input.list_id.as_deref() {
                    let exists: Option<i64> = transaction
                        .query_row(
                            "SELECT 1 FROM list WHERE id=?1 AND archived_at IS NULL",
                            [list_id],
                            |row| row.get(0),
                        )
                        .optional()?;
                    if exists.is_none() {
                        return Err(StoreError::NotFound);
                    }
                }
            }
            let timestamp = now();
            let mut tasks = Vec::with_capacity(inputs.len());
            for input in inputs {
                let task = Task {
                    id: Uuid::new_v4().to_string(),
                    list_id: input.list_id,
                    title: input.title.trim().to_owned(),
                    note: input.note,
                    status: TaskStatus::Open,
                    execution_date: input.execution_date,
                    due_date: input.due_date,
                    completed_at: None,
                    created_at: timestamp.clone(),
                    updated_at: timestamp.clone(),
                };
                transaction.execute(
                    "INSERT INTO task(id,list_id,title,note,status,execution_date,due_date,created_at,updated_at)
                     VALUES(?1,?2,?3,?4,'open',?5,?6,?7,?8)",
                    params![
                        task.id,
                        task.list_id,
                        task.title,
                        task.note,
                        task.execution_date,
                        task.due_date,
                        task.created_at,
                        task.updated_at
                    ],
                )?;
                tasks.push(task);
            }
            let refs = json!(tasks.iter().map(|task| task.id.clone()).collect::<Vec<_>>());
            let (tasks, truncated) = bounded_task_projections(tasks.iter(), 10);
            Ok((
                json!({ "tasks": tasks, "truncated": truncated }),
                refs,
                true,
            ))
        }
        "update_task" => {
            let object = tool_arguments_object("update_task", arguments)?;
            let task_id = canonical_uuid(
                required_string_field("update_task", object, "taskId")?,
                "update_task.taskId",
            )?;

            // The Web agent's flat shape is canonical. The briefly shipped native
            // preview declared a nested `update` object, so accept that exact legacy
            // shape too. Mixing the two would make precedence ambiguous and is rejected.
            let mut update_object = if let Some(nested) = object.get("update") {
                ensure_only_fields("update_task", object, &["taskId", "update"])?;
                nested
                    .as_object()
                    .ok_or_else(|| {
                        StoreError::Invalid("update_task.update must be an object".to_owned())
                    })?
                    .clone()
            } else {
                ensure_only_fields(
                    "update_task",
                    object,
                    &[
                        "taskId",
                        "title",
                        "note",
                        "listId",
                        "executionDate",
                        "dueDate",
                    ],
                )?;
                object
                    .iter()
                    .filter(|(key, _)| key.as_str() != "taskId")
                    .map(|(key, value)| (key.clone(), value.clone()))
                    .collect()
            };
            ensure_only_fields(
                "update_task.update",
                &update_object,
                &["title", "note", "listId", "executionDate", "dueDate"],
            )?;
            optional_string_field("update_task.update", &update_object, "title", false)?;
            optional_string_field("update_task.update", &update_object, "note", false)?;
            optional_string_field("update_task.update", &update_object, "listId", true)?;
            optional_string_field("update_task.update", &update_object, "executionDate", true)?;
            optional_string_field("update_task.update", &update_object, "dueDate", true)?;

            // Canonical Web calls clear a deadline with an empty string. Normalize it
            // to the native model's explicit null representation before deserializing.
            for field in ["executionDate", "dueDate"] {
                if update_object.get(field).and_then(Value::as_str) == Some("") {
                    update_object.insert(field.to_owned(), Value::Null);
                }
            }
            let update: UpdateTaskInput = serde_json::from_value(Value::Object(update_object))
                .map_err(|_| StoreError::Invalid("invalid update_task arguments".to_owned()))?;
            validate_task_update(&update)?;
            let existing: Task = transaction.query_row(
                "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at FROM task WHERE id=?1",
                [&task_id],
                row_to_task,
            ).optional()?.ok_or(StoreError::NotFound)?;
            let list_id = update
                .list_id
                .clone()
                .unwrap_or_else(|| existing.list_id.clone())
                .map(|value| canonical_uuid(&value, "update_task.listId"))
                .transpose()?;
            if let Some(list_id) = list_id.as_deref() {
                let exists: Option<i64> = transaction
                    .query_row(
                        "SELECT 1 FROM list WHERE id=?1 AND archived_at IS NULL",
                        [list_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                if exists.is_none() {
                    return Err(StoreError::NotFound);
                }
            }
            let status = update.status.unwrap_or(existing.status);
            let timestamp = now();
            let completed_at = if status == TaskStatus::Completed {
                existing
                    .completed_at
                    .clone()
                    .or_else(|| Some(timestamp.clone()))
            } else {
                None
            };
            transaction.execute(
                "UPDATE task SET list_id=?1,title=?2,note=?3,status=?4,execution_date=?5,due_date=?6,completed_at=?7,updated_at=?8 WHERE id=?9",
                params![
                    list_id,
                    update.title.as_deref().unwrap_or(&existing.title).trim(),
                    update.note.as_deref().unwrap_or(&existing.note),
                    status.as_str(),
                    update
                        .execution_date
                        .clone()
                        .unwrap_or_else(|| existing.execution_date.clone()),
                    update.due_date.clone().unwrap_or_else(|| existing.due_date.clone()),
                    completed_at,
                    timestamp,
                    task_id
                ],
            )?;
            let task: Task = transaction.query_row(
                "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at FROM task WHERE id=?1",
                [&task_id],
                row_to_task,
            )?;
            let (task_projection, truncated) = bounded_task_projection(&task);
            Ok((
                json!({ "task": task_projection, "truncated": truncated }),
                json!([task.id]),
                true,
            ))
        }
        "find_related" => {
            let object = tool_arguments_object("find_related", arguments)?;
            ensure_only_fields("find_related", object, &["query"])?;
            let query = required_string_field("find_related", object, "query")?.trim();
            if query.is_empty() {
                return Err(StoreError::Invalid(
                    "find_related.query must not be empty".to_owned(),
                ));
            }
            if query.chars().count() > 200 {
                return Err(StoreError::Invalid(
                    "find_related.query exceeds 200 characters".to_owned(),
                ));
            }
            let words = query
                .split_whitespace()
                .map(|word| escape_like_pattern(&word.to_lowercase()))
                .collect::<Vec<_>>();
            let predicates = std::iter::repeat_n(
                "(lower(title) LIKE ? ESCAPE '\\' OR lower(note) LIKE ? ESCAPE '\\')",
                words.len(),
            )
            .collect::<Vec<_>>()
            .join(" OR ");
            let patterns = words
                .into_iter()
                .flat_map(|word| {
                    let pattern = format!("%{word}%");
                    [pattern.clone(), pattern]
                })
                .collect::<Vec<_>>();
            let mut statement = transaction.prepare(&format!(
                "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at
                 FROM task WHERE {predicates}
                 ORDER BY CASE WHEN status='open' THEN 0 ELSE 1 END, updated_at DESC LIMIT 11"
            ))?;
            let tasks = statement
                .query_map(params_from_iter(patterns.iter()), row_to_task)?
                .collect::<Result<Vec<_>, _>>()?;
            let (tasks, truncated) = bounded_task_projections(tasks.iter(), 10);
            Ok((
                json!({ "tasks": tasks, "truncated": truncated }),
                json!([]),
                false,
            ))
        }
        "list_state" => {
            let object = tool_arguments_object("list_state", arguments)?;
            ensure_only_fields(
                "list_state",
                object,
                &["executionDate", "status", "listId", "cursor", "pageSize"],
            )?;
            optional_string_field("list_state", object, "executionDate", false)?;
            optional_string_field("list_state", object, "status", false)?;
            optional_string_field("list_state", object, "listId", false)?;
            let execution_date = object.get("executionDate").and_then(Value::as_str);
            if let Some(value) = execution_date {
                validate_local_date(value, "executionDate")?;
            }
            let status = object
                .get("status")
                .and_then(Value::as_str)
                .map(|value| {
                    TaskStatus::parse(value).ok_or_else(|| {
                        StoreError::Invalid(
                            "list_state.status must be open or completed".to_owned(),
                        )
                    })
                })
                .transpose()?;
            let list_id = object
                .get("listId")
                .and_then(Value::as_str)
                .map(|value| canonical_uuid(value, "list_state.listId"))
                .transpose()?;
            if let Some(list_id) = list_id.as_deref() {
                let exists: Option<i64> = transaction
                    .query_row(
                        "SELECT 1 FROM list WHERE id=?1 AND archived_at IS NULL",
                        [list_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                if exists.is_none() {
                    return Err(StoreError::NotFound);
                }
            }
            let has_task_filter = execution_date.is_some() || status.is_some() || list_id.is_some();
            let mut cursor = object
                .get("cursor")
                .map(|value| {
                    serde_json::from_value::<TaskPageCursor>(value.clone()).map_err(|_| {
                        StoreError::Invalid(
                            "list_state.cursor must be a pagination cursor returned by list_state"
                                .to_owned(),
                        )
                    })
                })
                .transpose()?;
            let page_size = match object.get("pageSize") {
                None => ASSISTANT_FILTERED_TASK_PAGE_SIZE,
                Some(value) => value
                    .as_u64()
                    .and_then(|value| usize::try_from(value).ok())
                    .filter(|value| (1..=ASSISTANT_FILTERED_TASK_PAGE_SIZE).contains(value))
                    .ok_or_else(|| {
                        StoreError::Invalid(
                            "list_state.pageSize must be an integer between 1 and 50".to_owned(),
                        )
                    })?,
            };
            if !has_task_filter && (cursor.is_some() || object.contains_key("pageSize")) {
                return Err(StoreError::Invalid(
                    "list_state cursor and pageSize require executionDate, status, or listId"
                        .to_owned(),
                ));
            }
            let task_revision: i64 = transaction.query_row(
                "SELECT revision FROM task_data_revision WHERE singleton=1",
                [],
                |row| row.get(0),
            )?;
            if let Some(cursor) = cursor.as_mut() {
                cursor.task_id = canonical_uuid(&cursor.task_id, "list_state.cursor.taskId")?;
                if let Some(filter_list_id) = cursor.filter_list_id.as_mut() {
                    *filter_list_id =
                        canonical_uuid(filter_list_id, "list_state.cursor.filterListId")?;
                }
                if cursor.task_revision != task_revision {
                    return Err(StoreError::Conflict("list_state_cursor_stale"));
                }
                if cursor.filter_execution_date.as_deref() != execution_date
                    || cursor.filter_status != status
                    || cursor.filter_list_id.as_deref() != list_id.as_deref()
                {
                    return Err(StoreError::Invalid(
                        "list_state.cursor does not match the active filters".to_owned(),
                    ));
                }
                chrono::DateTime::parse_from_rfc3339(&cursor.updated_at).map_err(|_| {
                    StoreError::Invalid(
                        "list_state.cursor contains an invalid updatedAt".to_owned(),
                    )
                })?;
                if status.is_some_and(|status| status != cursor.status) {
                    return Err(StoreError::Invalid(
                        "list_state.cursor status does not match the active status filter"
                            .to_owned(),
                    ));
                }
                validate_task_page_cursor(
                    transaction,
                    cursor,
                    execution_date,
                    status,
                    list_id.as_deref(),
                )?;
            }
            let revision: i64 = transaction.query_row(
                "SELECT revision FROM app_revision WHERE singleton=1",
                [],
                |row| row.get(0),
            )?;
            let open_count = if status.is_none_or(|value| value == TaskStatus::Open) {
                filtered_task_count(
                    transaction,
                    TaskStatus::Open,
                    execution_date,
                    list_id.as_deref(),
                )?
            } else {
                0
            };
            let completed_count = if status.is_none_or(|value| value == TaskStatus::Completed) {
                filtered_task_count(
                    transaction,
                    TaskStatus::Completed,
                    execution_date,
                    list_id.as_deref(),
                )?
            } else {
                0
            };
            let runtime_count: i64 = transaction.query_row(
                "SELECT count(DISTINCT session_id) FROM terminal_run
                 WHERE state IN ('starting','running','stopping')",
                [],
                |row| row.get(0),
            )?;
            let unread_count: i64 = transaction.query_row(
                "SELECT count(*) FROM terminal_session
                 WHERE status_sequence > seen_status_sequence",
                [],
                |row| row.get(0),
            )?;
            let counts = json!({
                "open": open_count,
                "completed": completed_count,
                "runningOrQueuedSessions": runtime_count,
                "unreadSessions": unread_count,
            });
            if has_task_filter {
                let tasks = filtered_task_page(
                    transaction,
                    status,
                    execution_date,
                    list_id.as_deref(),
                    cursor.as_ref(),
                    page_size,
                )?;
                return Ok((
                    filtered_list_state_page_result(
                        revision,
                        task_revision,
                        counts,
                        execution_date,
                        status,
                        list_id.as_deref(),
                        tasks,
                        page_size,
                    ),
                    json!([]),
                    false,
                ));
            }
            let (lists, lists_truncated) = tool_list_projections(transaction, 30)?;
            let (open, open_truncated) =
                tool_task_projections(transaction, TaskStatus::Open, None, None, 50)?;
            let (completed, completed_truncated) =
                tool_task_projections(transaction, TaskStatus::Completed, None, None, 50)?;
            let (runtime_sessions, runtime_truncated) =
                terminal_session_summaries(transaction, true, false, 20)?;
            let (unread_sessions, unread_truncated) =
                terminal_session_summaries(transaction, false, true, 20)?;
            let truncated = open_truncated
                || completed_truncated
                || lists_truncated
                || runtime_truncated
                || unread_truncated;
            Ok((
                fit_list_state_result(
                    revision,
                    counts,
                    lists,
                    open,
                    completed,
                    runtime_sessions,
                    unread_sessions,
                    truncated,
                ),
                json!([]),
                false,
            ))
        }
        "list_lists" => {
            let object = tool_arguments_object("list_lists", arguments)?;
            ensure_only_fields("list_lists", object, &[])?;
            let (lists, truncated) = tool_list_projections(transaction, 50)?;
            Ok((fit_list_result(lists, truncated), json!([]), false))
        }
        _ => Err(StoreError::Invalid("unsupported assistant tool".to_owned())),
    }
}

fn tool_arguments_object<'a>(
    tool: &str,
    arguments: &'a Value,
) -> StoreResult<&'a serde_json::Map<String, Value>> {
    arguments
        .as_object()
        .ok_or_else(|| StoreError::Invalid(format!("{tool} arguments must be an object")))
}

fn assistant_delete_task_id(arguments: &Value) -> StoreResult<String> {
    let object = tool_arguments_object("delete_task", arguments)?;
    ensure_only_fields("delete_task", object, &["taskId"])?;
    canonical_uuid(
        required_string_field("delete_task", object, "taskId")?,
        "delete_task.taskId",
    )
}

fn ensure_only_fields(
    scope: &str,
    object: &serde_json::Map<String, Value>,
    allowed: &[&str],
) -> StoreResult<()> {
    if let Some(field) = object
        .keys()
        .find(|field| !allowed.contains(&field.as_str()))
    {
        return Err(StoreError::Invalid(format!(
            "{scope} does not allow field {field}"
        )));
    }
    Ok(())
}

fn required_string_field<'a>(
    scope: &str,
    object: &'a serde_json::Map<String, Value>,
    field: &str,
) -> StoreResult<&'a str> {
    object
        .get(field)
        .ok_or_else(|| StoreError::Invalid(format!("{scope}.{field} is required")))?
        .as_str()
        .ok_or_else(|| StoreError::Invalid(format!("{scope}.{field} must be a string")))
}

fn optional_string_field(
    scope: &str,
    object: &serde_json::Map<String, Value>,
    field: &str,
    allow_null: bool,
) -> StoreResult<()> {
    let Some(value) = object.get(field) else {
        return Ok(());
    };
    if value.is_string() || (allow_null && value.is_null()) {
        return Ok(());
    }
    let expected = if allow_null {
        "a string or null"
    } else {
        "a string"
    };
    Err(StoreError::Invalid(format!(
        "{scope}.{field} must be {expected}"
    )))
}

fn escape_like_pattern(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        if matches!(character, '\\' | '%' | '_') {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

fn tool_list_projections(
    transaction: &Transaction<'_>,
    limit: usize,
) -> rusqlite::Result<(Vec<Value>, bool)> {
    // Repository paths are intentionally absent: they are local execution
    // capabilities and must never be sent to Gemini as assistant context.
    let mut statement = transaction.prepare(
        "SELECT id,name,color FROM list
         WHERE archived_at IS NULL ORDER BY created_at LIMIT ?1",
    )?;
    let rows = statement
        .query_map([limit as i64 + 1], |row| {
            let (name, name_truncated) = truncate_utf8(&row.get::<_, String>(1)?, 192);
            let (color, color_truncated) = truncate_utf8(&row.get::<_, String>(2)?, 48);
            let truncated = name_truncated || color_truncated;
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "name": name,
                "color": color,
                "truncated": truncated,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let truncated = rows.len() > limit
        || rows.iter().any(|row| {
            row.get("truncated")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        });
    Ok((rows.into_iter().take(limit).collect(), truncated))
}

fn tool_task_projections(
    transaction: &Transaction<'_>,
    status: TaskStatus,
    execution_date: Option<&str>,
    list_id: Option<&str>,
    limit: usize,
) -> rusqlite::Result<(Vec<Value>, bool)> {
    let (filter, values) = task_filter(status, execution_date, list_id);
    let mut statement = transaction.prepare(&format!(
        "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at
         FROM task WHERE {filter} ORDER BY updated_at DESC LIMIT {}",
        limit + 1
    ))?;
    let tasks = statement
        .query_map(params_from_iter(values.iter()), row_to_task)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(bounded_task_projections(tasks.iter(), limit))
}

fn filtered_task_page(
    transaction: &Transaction<'_>,
    status: Option<TaskStatus>,
    execution_date: Option<&str>,
    list_id: Option<&str>,
    cursor: Option<&TaskPageCursor>,
    page_size: usize,
) -> rusqlite::Result<Vec<Task>> {
    let mut predicates = Vec::new();
    let mut values = Vec::<SqlValue>::new();
    if let Some(status) = status {
        predicates.push("status=?".to_owned());
        values.push(SqlValue::Text(status.as_str().to_owned()));
    }
    if let Some(execution_date) = execution_date {
        predicates.push("execution_date=?".to_owned());
        values.push(SqlValue::Text(execution_date.to_owned()));
    }
    if let Some(list_id) = list_id {
        predicates.push("list_id=?".to_owned());
        values.push(SqlValue::Text(list_id.to_owned()));
    }
    if let Some(cursor) = cursor {
        let rank = task_status_rank(cursor.status);
        predicates.push(
            "(
                (CASE status WHEN 'open' THEN 0 ELSE 1 END) > ? OR
                ((CASE status WHEN 'open' THEN 0 ELSE 1 END) = ? AND
                    (updated_at < ? OR (updated_at = ? AND id > ?)))
             )"
            .to_owned(),
        );
        values.extend([
            SqlValue::Integer(rank),
            SqlValue::Integer(rank),
            SqlValue::Text(cursor.updated_at.clone()),
            SqlValue::Text(cursor.updated_at.clone()),
            SqlValue::Text(cursor.task_id.clone()),
        ]);
    }
    let filter = if predicates.is_empty() {
        "1=1".to_owned()
    } else {
        predicates.join(" AND ")
    };
    let mut statement = transaction.prepare(&format!(
        "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at
         FROM task WHERE {filter}
         ORDER BY CASE status WHEN 'open' THEN 0 ELSE 1 END, updated_at DESC, id ASC
         LIMIT {}",
        page_size + 1
    ))?;
    statement
        .query_map(params_from_iter(values.iter()), row_to_task)?
        .collect::<rusqlite::Result<Vec<_>>>()
}

fn validate_task_page_cursor(
    transaction: &Transaction<'_>,
    cursor: &TaskPageCursor,
    execution_date: Option<&str>,
    status: Option<TaskStatus>,
    list_id: Option<&str>,
) -> StoreResult<()> {
    let task = transaction
        .query_row(
            "SELECT id,list_id,title,note,status,execution_date,due_date,completed_at,created_at,updated_at
             FROM task WHERE id=?1",
            [&cursor.task_id],
            row_to_task,
        )
        .optional()?
        .ok_or_else(|| {
            StoreError::Invalid("list_state.cursor task key does not exist".to_owned())
        })?;
    let matches = task.status == cursor.status
        && task.updated_at == cursor.updated_at
        && status.is_none_or(|status| task.status == status)
        && execution_date.is_none_or(|date| task.execution_date.as_deref() == Some(date))
        && list_id.is_none_or(|list_id| task.list_id.as_deref() == Some(list_id));
    if !matches {
        return Err(StoreError::Invalid(
            "list_state.cursor task key does not match the active filters".to_owned(),
        ));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn filtered_list_state_page_result(
    revision: i64,
    task_revision: i64,
    counts: Value,
    execution_date: Option<&str>,
    status: Option<TaskStatus>,
    list_id: Option<&str>,
    tasks: Vec<Task>,
    page_size: usize,
) -> Value {
    let filters = json!({
        "executionDate": execution_date,
        "status": status,
        "listId": list_id,
    });
    let mut open = Vec::new();
    let mut completed = Vec::new();
    let mut content_truncated = false;
    let mut accepted = 0usize;
    let mut result = filtered_page_value(
        revision,
        task_revision,
        &counts,
        &filters,
        &open,
        &completed,
        page_size,
        0,
        tasks.len() as i64,
        None,
        !tasks.is_empty(),
        false,
    );

    for task in tasks.iter().take(page_size) {
        let (projection, item_truncated) = bounded_task_projection(task);
        match task.status {
            TaskStatus::Open => open.push(projection),
            TaskStatus::Completed => completed.push(projection),
        }
        let candidate_content_truncated = content_truncated || item_truncated;
        let candidate_accepted = accepted + 1;
        let has_more = candidate_accepted < tasks.len();
        let next_cursor = has_more
            .then(|| task_page_cursor_value(task, task_revision, execution_date, status, list_id));
        let candidate = filtered_page_value(
            revision,
            task_revision,
            &counts,
            &filters,
            &open,
            &completed,
            page_size,
            candidate_accepted,
            tasks.len() as i64,
            next_cursor,
            has_more,
            candidate_content_truncated,
        );
        if candidate.to_string().len() > ASSISTANT_TOOL_RESULT_MAX_BYTES {
            match task.status {
                TaskStatus::Open => {
                    open.pop();
                }
                TaskStatus::Completed => {
                    completed.pop();
                }
            }
            break;
        }
        content_truncated = candidate_content_truncated;
        accepted = candidate_accepted;
        result = candidate;
    }

    // A single bounded task projection is far below the 8 KiB result ceiling.
    // Keep the guard explicit so a future projection expansion cannot create a
    // cursor that makes no progress.
    debug_assert!(tasks.is_empty() || accepted > 0);
    result
}

#[allow(clippy::too_many_arguments)]
fn filtered_page_value(
    revision: i64,
    task_revision: i64,
    counts: &Value,
    filters: &Value,
    open: &[Value],
    completed: &[Value],
    page_size: usize,
    returned: usize,
    fetched: i64,
    next_cursor: Option<Value>,
    has_more: bool,
    content_truncated: bool,
) -> Value {
    let total = counts["open"].as_i64().unwrap_or_default()
        + counts["completed"].as_i64().unwrap_or_default();
    let next = if has_more {
        Some(
            "结果还有下一页；保持 executionDate/status/listId 不变，并把 pagination.nextCursor 原样传入 cursor。",
        )
    } else if content_truncated {
        Some("任务集合已完整返回；个别标题或备注为控制上下文长度已截短。")
    } else {
        None
    };
    json!({
        "revision": revision,
        "taskRevision": task_revision,
        "filters": filters,
        "counts": counts,
        "lists": [],
        "tasks": { "open": open, "completed": completed },
        "runningOrQueuedSessions": [],
        "unreadSessions": [],
        "pagination": {
            "pageSize": page_size,
            "taskRevision": task_revision,
            "returned": returned,
            "total": total,
            "fetchedForPage": fetched,
            "hasMore": has_more,
            "nextCursor": next_cursor,
        },
        "truncated": content_truncated,
        "next": next,
    })
}

fn task_page_cursor_value(
    task: &Task,
    task_revision: i64,
    execution_date: Option<&str>,
    status: Option<TaskStatus>,
    list_id: Option<&str>,
) -> Value {
    let mut cursor = json!({
        "taskRevision": task_revision,
        "status": task.status,
        "updatedAt": task.updated_at,
        "taskId": task.id,
    });
    let object = cursor.as_object_mut().expect("cursor is an object");
    if let Some(execution_date) = execution_date {
        object.insert(
            "filterExecutionDate".to_owned(),
            Value::String(execution_date.to_owned()),
        );
    }
    if let Some(status) = status {
        object.insert("filterStatus".to_owned(), json!(status));
    }
    if let Some(list_id) = list_id {
        object.insert("filterListId".to_owned(), Value::String(list_id.to_owned()));
    }
    cursor
}

fn task_status_rank(status: TaskStatus) -> i64 {
    match status {
        TaskStatus::Open => 0,
        TaskStatus::Completed => 1,
    }
}

fn filtered_task_count(
    transaction: &Transaction<'_>,
    status: TaskStatus,
    execution_date: Option<&str>,
    list_id: Option<&str>,
) -> rusqlite::Result<i64> {
    let (filter, values) = task_filter(status, execution_date, list_id);
    transaction.query_row(
        &format!("SELECT count(*) FROM task WHERE {filter}"),
        params_from_iter(values.iter()),
        |row| row.get(0),
    )
}

fn task_filter(
    status: TaskStatus,
    execution_date: Option<&str>,
    list_id: Option<&str>,
) -> (String, Vec<String>) {
    let mut predicates = vec!["status=?".to_owned()];
    let mut values = vec![status.as_str().to_owned()];
    if let Some(value) = execution_date {
        predicates.push("execution_date=?".to_owned());
        values.push(value.to_owned());
    }
    if let Some(value) = list_id {
        predicates.push("list_id=?".to_owned());
        values.push(value.to_owned());
    }
    (predicates.join(" AND "), values)
}

fn bounded_task_projections<'a>(
    tasks: impl IntoIterator<Item = &'a Task>,
    max_items: usize,
) -> (Vec<Value>, bool) {
    let tasks = tasks.into_iter().collect::<Vec<_>>();
    let mut truncated = tasks.len() > max_items;
    let projected = tasks
        .into_iter()
        .take(max_items)
        .map(|task| {
            let (value, item_truncated) = bounded_task_projection(task);
            truncated |= item_truncated;
            value
        })
        .collect();
    (projected, truncated)
}

fn bounded_task_projection(task: &Task) -> (Value, bool) {
    let (title, title_truncated) = truncate_utf8(&task.title, 192);
    let (note, note_truncated) = truncate_utf8(&task.note, 96);
    let truncated = title_truncated || note_truncated;
    (
        json!({
            "id": task.id,
            "listId": task.list_id,
            "title": title,
            "titleTruncated": title_truncated,
            "note": note,
            "noteTruncated": note_truncated,
            "status": task.status,
            "executionDate": task.execution_date,
            "dueDate": task.due_date,
            "updatedAt": task.updated_at,
        }),
        truncated,
    )
}

fn terminal_session_summaries(
    transaction: &Transaction<'_>,
    active_only: bool,
    unread_only: bool,
    limit: i64,
) -> rusqlite::Result<(Vec<Value>, bool)> {
    let mut statement = transaction.prepare(
        "SELECT s.id,s.task_id,t.title,
                coalesce((SELECT r.state FROM terminal_run r
                          WHERE r.session_id=s.id AND r.state IN ('starting','running','stopping')
                          ORDER BY r.ordinal DESC LIMIT 1),s.agent_status),
                s.status_sequence,s.seen_status_sequence,s.agent_status
         FROM terminal_session s JOIN task t ON t.id=s.task_id
         WHERE (NOT ?1 OR EXISTS(SELECT 1 FROM terminal_run r
                                 WHERE r.session_id=s.id AND r.state IN ('starting','running','stopping')))
           AND (NOT ?2 OR s.status_sequence>s.seen_status_sequence)
         ORDER BY s.updated_at DESC LIMIT ?3",
    )?;
    let rows = statement
        .query_map(params![active_only, unread_only, limit + 1], |row| {
            let title = row.get::<_, String>(2)?;
            let (title, title_truncated) = truncate_utf8(&title, 192);
            Ok(json!({
                "sessionId": row.get::<_, String>(0)?,
                "taskId": row.get::<_, String>(1)?,
                "taskTitle": title,
                "taskTitleTruncated": title_truncated,
                "state": row.get::<_, String>(3)?,
                "lastAgentSequence": row.get::<_, i64>(4)?,
                "lastReadSequence": row.get::<_, i64>(5)?,
                "agentStatus": row.get::<_, String>(6)?,
            }))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let truncated = rows.len() > limit as usize
        || rows.iter().any(|row| {
            row.get("taskTitleTruncated")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        });
    Ok((rows.into_iter().take(limit as usize).collect(), truncated))
}

fn fit_list_result(mut lists: Vec<Value>, mut truncated: bool) -> Value {
    loop {
        let value = json!({
            "lists": lists.clone(),
            "truncated": truncated,
            "next": truncated.then_some("结果已截断；请让用户指定目标清单后再继续查询。"),
        });
        if value.to_string().len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES {
            return value;
        }
        truncated = true;
        if lists.len() > 1 {
            lists.pop();
        } else {
            return json!({
                "lists": lists,
                "truncated": true,
                "next": "结果已截断；请让用户指定目标清单后再继续查询。",
            });
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn fit_list_state_result(
    revision: i64,
    counts: Value,
    mut lists: Vec<Value>,
    mut open: Vec<Value>,
    mut completed: Vec<Value>,
    mut runtime_sessions: Vec<Value>,
    mut unread_sessions: Vec<Value>,
    mut truncated: bool,
) -> Value {
    let minimum_lists = usize::from(!lists.is_empty());
    let minimum_open = usize::from(!open.is_empty());
    let minimum_completed = usize::from(!completed.is_empty());
    loop {
        let value = json!({
            "revision": revision,
            "counts": counts.clone(),
            "lists": lists.clone(),
            "tasks": { "open": open.clone(), "completed": completed.clone() },
            "runningOrQueuedSessions": runtime_sessions.clone(),
            "unreadSessions": unread_sessions.clone(),
            "truncated": truncated,
            "next": truncated.then_some("结果已截断；请使用 find_related 并提供更具体的任务关键词。"),
        });
        if value.to_string().len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES {
            return value;
        }
        truncated = true;
        let candidates = [
            (lists.len().saturating_sub(minimum_lists), 0usize),
            (open.len().saturating_sub(minimum_open), 1),
            (completed.len().saturating_sub(minimum_completed), 2),
            (runtime_sessions.len(), 3),
            (unread_sessions.len(), 4),
        ];
        let Some((_, selected)) = candidates
            .into_iter()
            .filter(|(removable, _)| *removable > 0)
            .max_by_key(|(removable, _)| *removable)
        else {
            // Each remaining projection has a strict field-size bound, so this
            // branch remains useful and comfortably below 8 KiB in practice.
            return json!({
                "revision": revision,
                "counts": counts,
                "lists": lists,
                "tasks": { "open": open, "completed": completed },
                "runningOrQueuedSessions": runtime_sessions,
                "unreadSessions": unread_sessions,
                "truncated": true,
                "next": "结果已截断；请使用 find_related 并提供更具体的任务关键词。",
            });
        };
        match selected {
            0 => {
                lists.pop();
            }
            1 => {
                open.pop();
            }
            2 => {
                completed.pop();
            }
            3 => {
                runtime_sessions.pop();
            }
            4 => {
                unread_sessions.pop();
            }
            _ => unreachable!(),
        }
    }
}

fn truncate_utf8(value: &str, max_bytes: usize) -> (String, bool) {
    if value.len() <= max_bytes {
        return (value.to_owned(), false);
    }
    let mut end = max_bytes.min(value.len());
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    (value[..end].to_owned(), true)
}

fn bounded_tool_result_json(tool_name: &str, value: &Value) -> String {
    let encoded = value.to_string();
    if encoded.len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES {
        encoded
    } else {
        json!({
            "tool": tool_name,
            "truncated": true,
            "originalBytes": encoded.len(),
            "message": "工具结果超过 8 KiB，已省略超出部分。请缩小查询范围。",
        })
        .to_string()
    }
}

fn bounded_tool_result_text(tool_name: &str, value: &str) -> String {
    if value.len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES {
        return value.to_owned();
    }
    serde_json::from_str::<Value>(value)
        .map(|value| bounded_tool_result_json(tool_name, &value))
        .unwrap_or_else(|_| {
            json!({
                "tool": tool_name,
                "truncated": true,
                "originalBytes": value.len(),
                "message": "工具结果超过 8 KiB，且不是有效 JSON，原内容已省略。",
            })
            .to_string()
        })
}

fn terminal_session_select(suffix: &str) -> String {
    format!(
        "SELECT id,task_id,runtime_kind,working_directory,provider_session_id,
         provider_binding_state,provider_binding_source,agent_status,status_sequence,
         seen_status_sequence,last_error_code,last_error_message,last_started_at,last_exited_at,
         created_at,updated_at,
         EXISTS(
           SELECT 1 FROM terminal_run
           WHERE terminal_run.session_id=terminal_session.id
             AND terminal_run.state IN ('starting','running','stopping')
         ) AS has_active_run
         FROM terminal_session {suffix}"
    )
}

fn terminal_run_select(suffix: &str) -> String {
    format!(
        "SELECT id,session_id,ordinal,launch_mode,state,provider_session_id_at_launch,
         exit_code,exit_reason,error_code,error_message,started_at,exited_at,created_at
         FROM terminal_run {suffix}"
    )
}

fn row_to_list(row: &rusqlite::Row<'_>) -> rusqlite::Result<List> {
    Ok(List {
        id: row.get(0)?,
        name: row.get(1)?,
        color: row.get(2)?,
        repository_path: row.get(3)?,
        archived_at: row.get(4)?,
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
    })
}

fn row_to_task(row: &rusqlite::Row<'_>) -> rusqlite::Result<Task> {
    let raw: String = row.get(4)?;
    Ok(Task {
        id: row.get(0)?,
        list_id: row.get(1)?,
        title: row.get(2)?,
        note: row.get(3)?,
        status: TaskStatus::parse(&raw).ok_or(rusqlite::Error::InvalidQuery)?,
        execution_date: row.get(5)?,
        due_date: row.get(6)?,
        completed_at: row.get(7)?,
        created_at: row.get(8)?,
        updated_at: row.get(9)?,
    })
}

fn row_to_task_attachment(row: &rusqlite::Row<'_>) -> rusqlite::Result<TaskAttachment> {
    Ok(TaskAttachment {
        id: row.get(0)?,
        task_id: row.get(1)?,
        original_name: row.get(2)?,
        size_bytes: row.get(3)?,
        mime_type: row.get(4)?,
        relative_path: row.get(5)?,
        created_at: row.get(6)?,
    })
}

fn upsert_runtime(connection: &Connection, runtime: &Runtime) -> rusqlite::Result<()> {
    connection.execute(
        "INSERT INTO runtime(kind,launch_path,resolved_path,version,status,auth_status,capabilities,provider_engine,detected_at,verified_at,verify_error)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
         ON CONFLICT(kind) DO UPDATE SET launch_path=excluded.launch_path,resolved_path=excluded.resolved_path,
         version=excluded.version,status=excluded.status,auth_status=excluded.auth_status,
         capabilities=excluded.capabilities,provider_engine=excluded.provider_engine,
         detected_at=excluded.detected_at,verified_at=excluded.verified_at,verify_error=excluded.verify_error",
        params![
            runtime.kind.as_str(),
            runtime.launch_path,
            runtime.resolved_path,
            runtime.version,
            runtime.status,
            runtime.auth_status,
            runtime.capabilities.to_string(),
            runtime.provider_engine,
            runtime.detected_at,
            runtime.verified_at,
            runtime.verify_error
        ],
    )?;
    Ok(())
}

fn runtime_from_connection(
    connection: &Connection,
    kind: RuntimeKind,
) -> StoreResult<Option<Runtime>> {
    Ok(connection
        .query_row(
            "SELECT kind,launch_path,resolved_path,version,status,auth_status,capabilities,provider_engine,detected_at,verified_at,verify_error FROM runtime WHERE kind=?1",
            [kind.as_str()],
            row_to_runtime,
        )
        .optional()?)
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

fn row_to_terminal_session(row: &rusqlite::Row<'_>) -> rusqlite::Result<TerminalSession> {
    let runtime: String = row.get(2)?;
    let binding: String = row.get(5)?;
    let status: String = row.get(7)?;
    Ok(TerminalSession {
        id: row.get(0)?,
        task_id: row.get(1)?,
        runtime_kind: RuntimeKind::parse(&runtime).ok_or(rusqlite::Error::InvalidQuery)?,
        working_directory: row.get(3)?,
        provider_session_id: row.get(4)?,
        provider_binding_state: ProviderBindingState::parse(&binding)
            .ok_or(rusqlite::Error::InvalidQuery)?,
        provider_binding_source: row.get(6)?,
        agent_status: TerminalAgentStatus::parse(&status).ok_or(rusqlite::Error::InvalidQuery)?,
        has_active_run: row.get(16)?,
        status_sequence: row.get(8)?,
        seen_status_sequence: row.get(9)?,
        last_error_code: row.get(10)?,
        last_error_message: row.get(11)?,
        last_started_at: row.get(12)?,
        last_exited_at: row.get(13)?,
        created_at: row.get(14)?,
        updated_at: row.get(15)?,
    })
}

fn row_to_terminal_run(row: &rusqlite::Row<'_>) -> rusqlite::Result<TerminalRun> {
    let launch_mode: String = row.get(3)?;
    let state: String = row.get(4)?;
    Ok(TerminalRun {
        id: row.get(0)?,
        session_id: row.get(1)?,
        ordinal: row.get(2)?,
        launch_mode: TerminalLaunchMode::parse(&launch_mode)
            .ok_or(rusqlite::Error::InvalidQuery)?,
        state: TerminalRunState::parse(&state).ok_or(rusqlite::Error::InvalidQuery)?,
        provider_session_id_at_launch: row.get(5)?,
        exit_code: row.get(6)?,
        exit_reason: row.get(7)?,
        error_code: row.get(8)?,
        error_message: row.get(9)?,
        started_at: row.get(10)?,
        exited_at: row.get(11)?,
        created_at: row.get(12)?,
    })
}

fn row_to_assistant_session(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssistantSession> {
    Ok(AssistantSession {
        id: row.get(0)?,
        title: row.get(1)?,
        created_at: row.get(2)?,
        updated_at: row.get(3)?,
        archived_at: row.get(4)?,
        last_sequence: row.get(5)?,
        is_running: row.get::<_, i64>(6)? != 0,
    })
}

fn assistant_turn_connection(
    connection: &Connection,
    id: &str,
) -> StoreResult<Option<AssistantTurn>> {
    Ok(connection
        .query_row(
            "SELECT id,session_id,ordinal,user_message_id,model_id,attempt_count,status,final_output,usage_json,error_code,error_message,started_at,ended_at,created_at,updated_at
             FROM assistant_turn WHERE id=?1",
            [id],
            row_to_assistant_turn,
        )
        .optional()?)
}

fn assistant_message_connection(
    connection: &Connection,
    id: &str,
) -> StoreResult<Option<AssistantMessage>> {
    Ok(connection
        .query_row(
            "SELECT id,session_id,turn_id,sequence,client_message_id,role,kind,body,payload_json,task_refs_json,created_at,updated_at
             FROM chat_message WHERE id=?1",
            [id],
            row_to_assistant_message,
        )
        .optional()?)
}

fn serialized_wire_bytes<T: serde::Serialize>(value: &T) -> usize {
    serde_json::to_vec(value).map_or(usize::MAX, |encoded| encoded.len() + 1)
}

fn collect_bounded_assistant_message_rows(
    rows: &mut rusqlite::Rows<'_>,
) -> rusqlite::Result<Vec<AssistantMessage>> {
    let mut messages = Vec::new();
    let mut retained_bytes = 0_usize;
    while let Some(row) = rows.next()? {
        let message = row_to_assistant_message(row)?;
        let message_bytes = serialized_wire_bytes(&message);
        if !messages.is_empty()
            && retained_bytes.saturating_add(message_bytes)
                > ASSISTANT_HISTORY_MESSAGE_PAGE_MAX_BYTES
        {
            break;
        }
        retained_bytes = retained_bytes.saturating_add(message_bytes);
        messages.push(message);
    }
    Ok(messages)
}

fn assistant_history_essential_timeline_ids(timeline: &[SessionTimelineItem]) -> HashSet<String> {
    let mut essential = timeline
        .iter()
        .filter(|item| matches!(item.kind.as_str(), "user" | "status" | "error"))
        .map(|item| item.id.clone())
        .collect::<HashSet<_>>();
    let mut last_assistant_by_turn = HashMap::<&str, &SessionTimelineItem>::new();
    for item in timeline.iter().filter(|item| item.kind == "assistant_text") {
        let replace = last_assistant_by_turn
            .get(item.turn_id.as_str())
            .is_none_or(|current| {
                (item.turn_ordinal, item.item_ordinal, item.sequence)
                    > (current.turn_ordinal, current.item_ordinal, current.sequence)
            });
        if replace {
            last_assistant_by_turn.insert(item.turn_id.as_str(), item);
        }
    }
    essential.extend(
        last_assistant_by_turn
            .into_values()
            .map(|item| item.id.clone()),
    );
    essential
}

fn assistant_history_partial_notice(
    session: &AssistantSession,
    active_turn: Option<&AssistantTurn>,
    timeline: &[SessionTimelineItem],
    after_sequence: i64,
) -> SessionTimelineItem {
    let tail = timeline.last();
    let turn_ordinal = tail
        .map(|item| item.turn_ordinal)
        .or_else(|| active_turn.map(|turn| turn.ordinal))
        .unwrap_or(0);
    let turn_id = tail
        .map(|item| item.turn_id.clone())
        .or_else(|| active_turn.map(|turn| turn.id.clone()))
        .unwrap_or_else(|| format!("standalone-history-{}", session.id));
    let item_ordinal = timeline
        .iter()
        .filter(|item| item.turn_ordinal == turn_ordinal)
        .map(|item| item.item_ordinal)
        .max()
        .unwrap_or(0)
        .saturating_add(1);
    let sequence = timeline
        .iter()
        .map(|item| item.sequence)
        .max()
        .unwrap_or_else(|| turn_ordinal.saturating_mul(1_000_000))
        .saturating_add(1);
    SessionTimelineItem {
        id: format!("assistant-history-partial-{}-{after_sequence}", session.id),
        session_id: session.id.clone(),
        turn_id,
        sequence,
        turn_ordinal,
        item_ordinal,
        kind: "status".to_owned(),
        body: "部分工具调用与思考步骤因历史页过大未加载；最终回复仍保留。".to_owned(),
        call_id: None,
        tool_name: None,
        input_json: None,
        output_text: None,
        tool_state: None,
        is_error: false,
        source_event_sequence: None,
        source_block_index: None,
        fidelity: "partial".to_owned(),
        metadata_json: Some(
            json!({
                "truncated":true,
                "reason":"history_detail_budget",
                "budgetBytes":ASSISTANT_HISTORY_DETAIL_PAGE_MAX_BYTES,
            })
            .to_string(),
        ),
        created_at: session.updated_at.clone(),
        updated_at: session.updated_at.clone(),
    }
}

fn row_to_assistant_turn(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssistantTurn> {
    Ok(AssistantTurn {
        id: row.get(0)?,
        session_id: row.get(1)?,
        ordinal: row.get(2)?,
        user_message_id: row.get(3)?,
        model_id: row.get(4)?,
        attempt_count: row.get(5)?,
        status: AssistantTurnStatus::parse(&row.get::<_, String>(6)?)
            .ok_or(rusqlite::Error::InvalidQuery)?,
        final_output: row.get(7)?,
        usage_json: row.get(8)?,
        error_code: row.get(9)?,
        error_message: row.get(10)?,
        started_at: row.get(11)?,
        ended_at: row.get(12)?,
        created_at: row.get(13)?,
        updated_at: row.get(14)?,
    })
}

fn row_to_assistant_message(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssistantMessage> {
    Ok(AssistantMessage {
        id: row.get(0)?,
        session_id: row.get(1)?,
        turn_id: row.get(2)?,
        sequence: row.get(3)?,
        client_message_id: row.get(4)?,
        role: row.get(5)?,
        kind: row.get(6)?,
        body: row.get(7)?,
        payload_json: row.get(8)?,
        task_refs_json: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
    })
}

fn row_to_assistant_step(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssistantStep> {
    Ok(AssistantStep {
        id: row.get(0)?,
        session_id: row.get(1)?,
        turn_id: row.get(2)?,
        sequence: row.get(3)?,
        interaction_ordinal: row.get(4)?,
        provider_step_index: row.get(5)?,
        kind: row.get(6)?,
        status: row.get(7)?,
        title: row.get(8)?,
        payload_json: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
    })
}

fn row_to_assistant_tool_execution(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AssistantToolExecution> {
    Ok(AssistantToolExecution {
        id: row.get(0)?,
        session_id: row.get(1)?,
        turn_id: row.get(2)?,
        step_id: row.get(3)?,
        call_id: row.get(4)?,
        tool_name: row.get(5)?,
        request_json: row.get(6)?,
        response_json: row.get(7)?,
        task_refs_json: row.get(8)?,
        is_error: row.get::<_, i64>(9)? != 0,
        status: row.get(10)?,
        error_code: row.get(11)?,
        error_message: row.get(12)?,
        created_at: row.get(13)?,
        updated_at: row.get(14)?,
    })
}

fn row_to_assistant_tool_summary(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AssistantToolSummary> {
    Ok(AssistantToolSummary {
        id: row.get(0)?,
        session_id: row.get(1)?,
        turn_id: row.get(2)?,
        call_id: row.get(3)?,
        tool_name: row.get(4)?,
        task_refs_json: row.get(5)?,
        is_error: row.get::<_, i64>(6)? != 0,
        status: row.get(7)?,
        created_at: row.get(8)?,
        updated_at: row.get(9)?,
    })
}

fn row_to_assistant_compaction(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssistantCompaction> {
    Ok(AssistantCompaction {
        session_id: row.get(0)?,
        through_sequence: row.get(1)?,
        summary: row.get(2)?,
        payload_json: row.get(3)?,
        created_at: row.get(4)?,
        updated_at: row.get(5)?,
    })
}

fn validate_session_title(value: &str) -> StoreResult<()> {
    if value.trim().is_empty() || value.chars().count() > 120 {
        return Err(StoreError::Invalid(
            "assistant session title must be 1-120 characters".to_owned(),
        ));
    }
    Ok(())
}

fn normalize_list_name(value: &str) -> StoreResult<String> {
    let value = value.trim();
    if value.is_empty() || value.chars().count() > 200 {
        return Err(StoreError::Invalid(
            "list name must be 1-200 characters".to_owned(),
        ));
    }
    Ok(value.to_owned())
}

fn validate_task_input(input: &CreateTaskInput) -> StoreResult<()> {
    if input.title.trim().is_empty() || input.title.trim().chars().count() > 500 {
        return Err(StoreError::Invalid(
            "task title must be 1-500 characters".to_owned(),
        ));
    }
    if input.note.chars().count() > 4000 {
        return Err(StoreError::Invalid(
            "task note exceeds 4000 characters".to_owned(),
        ));
    }
    if let Some(list_id) = input.list_id.as_deref() {
        canonical_uuid(list_id, "listId")?;
    }
    if let Some(execution_date) = input.execution_date.as_deref() {
        validate_local_date(execution_date, "executionDate")?;
    }
    if let Some(due_date) = input.due_date.as_deref() {
        validate_local_date(due_date, "dueDate")?;
    }
    Ok(())
}

fn validate_task_update(update: &UpdateTaskInput) -> StoreResult<()> {
    if let Some(title) = update.title.as_deref() {
        if title.trim().is_empty() || title.trim().chars().count() > 500 {
            return Err(StoreError::Invalid(
                "task title must be 1-500 characters".to_owned(),
            ));
        }
    }
    if let Some(note) = update.note.as_deref() {
        if note.chars().count() > 4000 {
            return Err(StoreError::Invalid(
                "task note exceeds 4000 characters".to_owned(),
            ));
        }
    }
    if let Some(Some(list_id)) = update.list_id.as_ref() {
        canonical_uuid(list_id, "listId")?;
    }
    if let Some(Some(execution_date)) = update.execution_date.as_ref() {
        validate_local_date(execution_date, "executionDate")?;
    }
    if let Some(Some(due_date)) = update.due_date.as_ref() {
        validate_local_date(due_date, "dueDate")?;
    }
    Ok(())
}

fn validate_local_date(value: &str, field: &str) -> StoreResult<()> {
    if value.len() != 10 {
        return Err(StoreError::Invalid(format!("{field} must be YYYY-MM-DD")));
    }
    let date = NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| StoreError::Invalid(format!("{field} must be YYYY-MM-DD")))?;
    if date.year() < 1 || date.format("%Y-%m-%d").to_string() != value {
        return Err(StoreError::Invalid(format!("{field} must be YYYY-MM-DD")));
    }
    Ok(())
}

fn validate_attachment_source_paths(source_paths: &[String]) -> StoreResult<()> {
    if source_paths.is_empty() || source_paths.len() > 20 {
        return Err(StoreError::Invalid(
            "sourcePaths must contain between 1 and 20 files".to_owned(),
        ));
    }
    if source_paths
        .iter()
        .any(|source| !Path::new(source).is_absolute())
    {
        return Err(StoreError::Invalid(
            "task attachment source paths must be absolute".to_owned(),
        ));
    }
    Ok(())
}

fn add_attachment_mutation_fingerprint(task_id: &str, source_paths: &[String]) -> String {
    json!({
        "taskId": task_id,
        "sourcePaths": source_paths,
    })
    .to_string()
}

fn remove_attachment_mutation_fingerprint(task_id: &str, attachment_id: &str) -> String {
    json!({
        "taskId": task_id,
        "attachmentId": attachment_id,
    })
    .to_string()
}

fn attachment_mutation_was_committed(
    connection: &Connection,
    client_mutation_id: &str,
    operation: &str,
    task_id: &str,
    request_fingerprint: &str,
) -> StoreResult<bool> {
    let existing = connection
        .query_row(
            "SELECT operation,task_id,request_fingerprint
             FROM task_attachment_mutation WHERE client_mutation_id=?1",
            [client_mutation_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            },
        )
        .optional()?;
    match existing {
        None => Ok(false),
        Some((stored_operation, stored_task_id, stored_fingerprint))
            if stored_operation == operation
                && stored_task_id == task_id
                && stored_fingerprint == request_fingerprint =>
        {
            Ok(true)
        }
        Some(_) => Err(StoreError::Conflict("attachment_mutation_conflict")),
    }
}

fn insert_attachment_mutation_receipt(
    transaction: &Transaction<'_>,
    client_mutation_id: &str,
    operation: &str,
    task_id: &str,
    request_fingerprint: &str,
    result_attachment_ids_json: &str,
) -> StoreResult<()> {
    transaction.execute(
        "INSERT INTO task_attachment_mutation(
           client_mutation_id,operation,task_id,request_fingerprint,result_attachment_ids_json,created_at
         ) VALUES(?1,?2,?3,?4,?5,?6)",
        params![
            client_mutation_id,
            operation,
            task_id,
            request_fingerprint,
            result_attachment_ids_json,
            now(),
        ],
    )?;
    Ok(())
}

fn task_record_exists(connection: &Connection, id: &str) -> StoreResult<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM task WHERE id=?1)",
        [id],
        |row| row.get::<_, i64>(0),
    )? != 0)
}

fn ensure_task_session_inactive(connection: &Connection, task_id: &str) -> StoreResult<()> {
    let active = connection.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM terminal_session AS session
           JOIN terminal_run AS run ON run.session_id=session.id
           WHERE session.task_id=?1 AND run.state IN ('starting','running','stopping')
         )",
        [task_id],
        |row| row.get::<_, i64>(0),
    )? != 0;
    if active {
        Err(StoreError::Conflict("task_session_active"))
    } else {
        Ok(())
    }
}

fn validate_provider_session_id(value: &str) -> StoreResult<()> {
    let value = value.trim();
    if value.is_empty() || value.len() > 512 || value.chars().any(char::is_control) {
        return Err(StoreError::Invalid(
            "providerSessionId must contain 1 to 512 printable bytes".to_owned(),
        ));
    }
    Ok(())
}

fn validate_binding_source(value: &str) -> StoreResult<()> {
    if matches!(
        value,
        "preallocated" | "session_start_hook" | "create_chat" | "session_store_scan" | "manual"
    ) {
        Ok(())
    } else {
        Err(StoreError::Invalid(
            "unknown provider binding source".to_owned(),
        ))
    }
}

fn canonical_uuid(value: &str, field: &str) -> StoreResult<String> {
    Uuid::parse_str(value)
        .map(|value| value.to_string())
        .map_err(|_| StoreError::Invalid(format!("{field} must be a UUID")))
}

fn now() -> String {
    Utc::now().to_rfc3339()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use tempfile::tempdir;

    fn runtime_record(
        status: &str,
        launch_path: Option<&str>,
        resolved_path: Option<&str>,
        verified_at: Option<&str>,
    ) -> Runtime {
        Runtime {
            kind: RuntimeKind::Codex,
            launch_path: launch_path.map(str::to_owned),
            resolved_path: resolved_path.map(str::to_owned),
            version: verified_at.map(|_| "codex-cli 1.2.3".to_owned()),
            status: status.to_owned(),
            auth_status: if status == "ready" {
                "authenticated".to_owned()
            } else {
                "required".to_owned()
            },
            capabilities: json!({"nativeResume": true}),
            provider_engine: None,
            detected_at: Some("2026-08-09T00:00:00Z".to_owned()),
            verified_at: verified_at.map(str::to_owned),
            verify_error: (status != "ready").then(|| "saved verification".to_owned()),
        }
    }

    fn running_assistant_turn(store: &Store, title: &str) -> QueuedAssistantTurn {
        let session = store.create_assistant_session(title).unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "测试任务工具",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        queued
    }

    fn first_filtered_cursor(store: &Store, queued: &QueuedAssistantTurn, call_id: &str) -> Value {
        let first = store
            .execute_assistant_tool(
                &queued.turn.id,
                call_id,
                "list_state",
                &json!({
                    "executionDate":"2026-08-10",
                    "status":"open",
                    "pageSize":1
                })
                .to_string(),
            )
            .unwrap();
        let first = serde_json::from_str::<Value>(&first.result_json).unwrap();
        assert_eq!(first["taskRevision"], first["pagination"]["taskRevision"]);
        first["pagination"]["nextCursor"].clone()
    }

    #[test]
    fn terminal_runs_resume_one_provider_and_keep_latest_run_in_bundle() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("终端任务", "", None, None, None).unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Codex, "/tmp")
            .unwrap();
        let first_run_id = Uuid::new_v4().to_string();
        let first = store
            .prepare_terminal_run(&session.id, &first_run_id)
            .unwrap();
        assert_eq!(first.active_run.as_ref().unwrap().ordinal, 1);
        store
            .bind_terminal_provider(
                &session.id,
                &first_run_id,
                "provider-session-1",
                "session_start_hook",
            )
            .unwrap();
        store
            .mark_terminal_run_started(&session.id, &first_run_id)
            .unwrap();
        let exited = store
            .finish_terminal_run(
                &session.id,
                &first_run_id,
                Some(0),
                "process_exit",
                None,
                None,
            )
            .unwrap();
        assert_eq!(exited.active_run.as_ref().unwrap().id, first_run_id);
        assert_eq!(
            exited.active_run.as_ref().unwrap().state,
            TerminalRunState::Exited
        );

        let second_run_id = Uuid::new_v4().to_string();
        let resumed = store
            .prepare_terminal_run(&session.id, &second_run_id)
            .unwrap();
        let run = resumed.active_run.unwrap();
        assert_eq!(run.ordinal, 2);
        assert_eq!(run.launch_mode, TerminalLaunchMode::Resume);
        assert_eq!(
            run.provider_session_id_at_launch.as_deref(),
            Some("provider-session-1")
        );
    }

    #[test]
    fn inactive_terminal_session_can_rebind_workspace_without_losing_provider_identity() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store
            .create_task("Moved workspace", "", None, None, None)
            .unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Claude, "/old/project")
            .unwrap();
        let provider_id = session.provider_session_id.clone();
        let completed_run_id = Uuid::new_v4().to_string();
        store
            .prepare_terminal_run(&session.id, &completed_run_id)
            .unwrap();
        store
            .mark_terminal_run_started(&session.id, &completed_run_id)
            .unwrap();
        store
            .finish_terminal_run(
                &session.id,
                &completed_run_id,
                Some(0),
                "process_exit",
                None,
                None,
            )
            .unwrap();

        let rebound = store
            .rebind_terminal_session_workspace(&session.id, "/replacement/project")
            .unwrap();
        assert_eq!(rebound.session.working_directory, "/replacement/project");
        assert_eq!(rebound.session.runtime_kind, RuntimeKind::Claude);
        assert_eq!(rebound.session.provider_session_id, provider_id);
        assert_eq!(
            rebound.session.provider_binding_source.as_deref(),
            Some("preallocated")
        );
        assert_eq!(
            rebound.active_run.as_ref().map(|run| run.id.as_str()),
            Some(completed_run_id.as_str())
        );
        assert_eq!(
            rebound.active_run.as_ref().map(|run| run.state),
            Some(TerminalRunState::Exited)
        );

        let revision = store.revision().unwrap();
        let replay = store
            .rebind_terminal_session_workspace(&session.id, "/replacement/project")
            .unwrap();
        assert_eq!(replay.session.working_directory, "/replacement/project");
        assert_eq!(store.revision().unwrap(), revision);
        assert!(matches!(
            store.rebind_terminal_session_workspace(&session.id, "relative/project"),
            Err(StoreError::Invalid(_))
        ));
    }

    #[test]
    fn active_terminal_session_rejects_workspace_rebind() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store
            .create_task("Active workspace", "", None, None, None)
            .unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Claude, "/old/project")
            .unwrap();
        store
            .prepare_terminal_run(&session.id, &Uuid::new_v4().to_string())
            .unwrap();

        let result = store.rebind_terminal_session_workspace(&session.id, "/replacement/project");
        assert!(matches!(
            result,
            Err(StoreError::Conflict("terminal_session_active"))
        ));
        assert_eq!(
            store
                .terminal_session(&session.id)
                .unwrap()
                .unwrap()
                .working_directory,
            "/old/project"
        );
    }

    #[test]
    fn claude_without_materialized_transcript_reuses_preallocated_id_as_fresh() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store
            .create_task("Claude terminal", "", None, None, None)
            .unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Claude, "/tmp")
            .unwrap();
        let provider_id = session.provider_session_id.clone().unwrap();
        let first_run_id = Uuid::new_v4().to_string();
        store
            .prepare_terminal_run(&session.id, &first_run_id)
            .unwrap();
        store
            .mark_terminal_run_started(&session.id, &first_run_id)
            .unwrap();
        store
            .finish_terminal_run(
                &session.id,
                &first_run_id,
                Some(0),
                "user_ended",
                None,
                None,
            )
            .unwrap();

        let fresh_retry = store
            .prepare_terminal_run_with_resume_readiness(
                &session.id,
                &Uuid::new_v4().to_string(),
                false,
            )
            .unwrap()
            .active_run
            .unwrap();
        assert_eq!(fresh_retry.ordinal, 2);
        assert_eq!(fresh_retry.launch_mode, TerminalLaunchMode::Fresh);
        assert_eq!(
            fresh_retry.provider_session_id_at_launch.as_deref(),
            Some(provider_id.as_str())
        );
    }

    #[test]
    fn claude_with_materialized_transcript_resumes_preallocated_id() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store
            .create_task("Claude resume", "", None, None, None)
            .unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Claude, "/tmp")
            .unwrap();
        let first_run_id = Uuid::new_v4().to_string();
        store
            .prepare_terminal_run(&session.id, &first_run_id)
            .unwrap();
        store
            .mark_terminal_run_started(&session.id, &first_run_id)
            .unwrap();
        store
            .finish_terminal_run(
                &session.id,
                &first_run_id,
                Some(0),
                "process_exit",
                None,
                None,
            )
            .unwrap();

        let resumed = store
            .prepare_terminal_run_with_resume_readiness(
                &session.id,
                &Uuid::new_v4().to_string(),
                true,
            )
            .unwrap()
            .active_run
            .unwrap();
        assert_eq!(resumed.launch_mode, TerminalLaunchMode::Resume);
    }

    #[test]
    fn kiro_process_lifecycle_projects_active_run_without_status_hooks() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store
            .create_task("Kiro terminal", "", None, None, None)
            .unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Kiro, "/tmp")
            .unwrap();
        assert!(!session.has_active_run);
        assert_eq!(session.agent_status, TerminalAgentStatus::Unknown);

        let run_id = Uuid::new_v4().to_string();
        let prepared = store.prepare_terminal_run(&session.id, &run_id).unwrap();
        assert!(prepared.session.has_active_run);
        let started = store
            .mark_terminal_run_started(&session.id, &run_id)
            .unwrap();
        assert!(started.session.has_active_run);
        assert_eq!(started.session.agent_status, TerminalAgentStatus::Unknown);
        assert!(
            store
                .bootstrap()
                .unwrap()
                .sessions
                .iter()
                .find(|candidate| candidate.id == session.id)
                .unwrap()
                .has_active_run
        );

        let exited = store
            .finish_terminal_run(&session.id, &run_id, Some(0), "process_exit", None, None)
            .unwrap();
        assert!(!exited.session.has_active_run);
        assert_eq!(exited.session.agent_status, TerminalAgentStatus::Unknown);
        assert!(
            !store
                .terminal_session(&session.id)
                .unwrap()
                .unwrap()
                .has_active_run
        );
    }

    #[test]
    fn terminal_run_lifecycle_retries_are_idempotent_but_conflicts_fail() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("retry", "", None, None, None).unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Claude, "/tmp")
            .unwrap();
        let run_id = Uuid::new_v4().to_string();
        store.prepare_terminal_run(&session.id, &run_id).unwrap();
        store
            .mark_terminal_run_started(&session.id, &run_id)
            .unwrap();
        assert_eq!(
            store
                .mark_terminal_run_started(&session.id, &run_id)
                .unwrap()
                .active_run
                .unwrap()
                .state,
            TerminalRunState::Running
        );
        store
            .mark_terminal_run_stopping(&session.id, &run_id)
            .unwrap();
        store
            .mark_terminal_run_stopping(&session.id, &run_id)
            .unwrap();
        store
            .finish_terminal_run(&session.id, &run_id, Some(0), "process_exit", None, None)
            .unwrap();
        store
            .finish_terminal_run(&session.id, &run_id, Some(0), "process_exit", None, None)
            .unwrap();
        assert!(matches!(
            store.finish_terminal_run(&session.id, &run_id, Some(1), "process_exit", None, None,),
            Err(StoreError::Conflict("terminal_run_result_conflict"))
        ));
        assert!(matches!(
            store.mark_terminal_run_started(&session.id, &run_id),
            Err(StoreError::Conflict("terminal_run_result_conflict"))
        ));
    }

    #[test]
    fn stopping_run_can_durably_record_a_runner_that_already_started() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store
            .create_task("started during end", "", None, None, None)
            .unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Codex, "/tmp")
            .unwrap();
        let run_id = Uuid::new_v4().to_string();
        store.prepare_terminal_run(&session.id, &run_id).unwrap();
        store
            .mark_terminal_run_stopping(&session.id, &run_id)
            .unwrap();

        let started = store
            .mark_terminal_run_started(&session.id, &run_id)
            .unwrap();
        let run = started.active_run.unwrap();
        assert_eq!(run.state, TerminalRunState::Stopping);
        assert!(run.started_at.is_some());
        assert!(started.session.last_started_at.is_some());

        let replay = store
            .mark_terminal_run_started(&session.id, &run_id)
            .unwrap();
        assert_eq!(replay.active_run.unwrap().started_at, run.started_at);
    }

    #[test]
    fn unstarted_launch_failure_allows_fresh_retry_but_started_unbound_requires_binding() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store
            .create_task("Codex retry", "", None, None, None)
            .unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Codex, "/tmp")
            .unwrap();

        let failed_run_id = Uuid::new_v4().to_string();
        store
            .prepare_terminal_run(&session.id, &failed_run_id)
            .unwrap();
        store
            .finish_terminal_run(
                &session.id,
                &failed_run_id,
                None,
                "launch_failed",
                Some("surface_failed"),
                Some("surface never started"),
            )
            .unwrap();
        let retry_id = Uuid::new_v4().to_string();
        let retry = store.prepare_terminal_run(&session.id, &retry_id).unwrap();
        assert_eq!(
            retry.active_run.unwrap().launch_mode,
            TerminalLaunchMode::Fresh
        );

        store
            .mark_terminal_run_started(&session.id, &retry_id)
            .unwrap();
        store
            .finish_terminal_run(&session.id, &retry_id, Some(1), "process_exit", None, None)
            .unwrap();
        assert!(matches!(
            store.prepare_terminal_run(&session.id, &Uuid::new_v4().to_string()),
            Err(StoreError::Conflict("provider_binding_required"))
        ));
    }

    #[test]
    fn duplicate_terminal_status_event_does_not_increment_attention_twice() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("status", "", None, None, None).unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Claude, "/tmp")
            .unwrap();
        let run_id = Uuid::new_v4().to_string();
        let event_id = Uuid::new_v4().to_string();
        store.prepare_terminal_run(&session.id, &run_id).unwrap();
        store
            .mark_terminal_run_started(&session.id, &run_id)
            .unwrap();
        let first = store
            .report_terminal_status(
                &event_id,
                &session.id,
                &run_id,
                TerminalAgentStatus::Blocked,
            )
            .unwrap();
        let replay = store
            .report_terminal_status(
                &event_id,
                &session.id,
                &run_id,
                TerminalAgentStatus::Blocked,
            )
            .unwrap();
        assert_eq!(first.session.status_sequence, 1);
        assert_eq!(replay.session.status_sequence, 1);
        assert!(matches!(
            store.report_terminal_status(
                &event_id,
                &session.id,
                &run_id,
                TerminalAgentStatus::Completed,
            ),
            Err(StoreError::Conflict("terminal_status_event_id_reused"))
        ));
    }

    #[test]
    fn manual_provider_binding_is_allowed_only_on_latest_run() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("恢复", "", None, None, None).unwrap();
        let session = store
            .create_terminal_session(&task.id, RuntimeKind::Kiro, "/tmp")
            .unwrap();
        let run_id = Uuid::new_v4().to_string();
        store.prepare_terminal_run(&session.id, &run_id).unwrap();
        store
            .finish_terminal_run(&session.id, &run_id, Some(0), "process_exit", None, None)
            .unwrap();
        let bound = store
            .bind_terminal_provider(&session.id, &run_id, "kiro-provider", "manual")
            .unwrap();
        assert_eq!(
            bound.session.provider_session_id.as_deref(),
            Some("kiro-provider")
        );
    }

    #[test]
    fn v4_migration_preserves_product_data_drops_agent_history_and_creates_secure_backup() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("todoagent.sqlite3");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(include_str!("schema.sql"))
                .unwrap();
            connection
                .execute_batch(
                    "DROP TABLE terminal_status_receipt;
                     DROP TABLE terminal_run;
                     DROP TABLE terminal_session;",
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO schema_migration(version,name,checksum,applied_at)
                     VALUES(4,'structured sessions','v4-test',?1)",
                    [now()],
                )
                .unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE task_session(id TEXT PRIMARY KEY);
                     CREATE TABLE session_turn(id TEXT PRIMARY KEY,session_id TEXT REFERENCES task_session(id));
                     CREATE TABLE session_message(id TEXT PRIMARY KEY,turn_id TEXT REFERENCES session_turn(id));
                     CREATE TABLE turn_event(id INTEGER PRIMARY KEY,turn_id TEXT REFERENCES session_turn(id));
                     CREATE TABLE session_timeline_item(id TEXT PRIMARY KEY,turn_id TEXT REFERENCES session_turn(id));
                     CREATE TABLE session_timeline_projection(turn_id TEXT PRIMARY KEY REFERENCES session_turn(id));
                     INSERT INTO task_session VALUES('legacy-session');",
                )
                .unwrap();
            let timestamp = now();
            let task_id = "abcdefab-cdef-4abc-8def-abcdefabc101";
            connection
                .execute(
                    "INSERT INTO task(id,title,note,status,created_at,updated_at)
                     VALUES(?1,'kept','note','open',?2,?2)",
                    params![task_id, timestamp],
                )
                .unwrap();
        }

        let migrated = Store::open(&path).unwrap();
        assert_eq!(migrated.health().unwrap()["schemaVersion"], 5);
        assert!(
            migrated
                .task("abcdefab-cdef-4abc-8def-abcdefabc101")
                .unwrap()
                .is_some()
        );
        assert!(table_exists(&migrated.connection, "terminal_session").unwrap());
        assert!(!table_exists(&migrated.connection, "task_session").unwrap());
        let backups = fs::read_dir(directory.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().contains(".v4-backup-"))
            .collect::<Vec<_>>();
        assert_eq!(backups.len(), 1);
        assert_eq!(
            backups[0].metadata().unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn failed_v4_migration_rolls_back_and_can_be_retried() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("todoagent.sqlite3");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(include_str!("schema.sql"))
                .unwrap();
            connection
                .execute_batch(
                    "DROP TABLE terminal_status_receipt;
                     DROP TABLE terminal_run;
                     DROP TABLE terminal_session;
                     INSERT INTO schema_migration(version,name,checksum,applied_at)
                       VALUES(4,'structured sessions','v4-test','now');
                     CREATE TABLE task_session(id TEXT PRIMARY KEY);
                     INSERT INTO task_session VALUES('legacy-session');
                     PRAGMA foreign_keys=OFF;
                     INSERT INTO task_attachment(
                       id,task_id,original_name,size_bytes,mime_type,relative_path,created_at
                     ) VALUES(
                       'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','missing-task','x.txt',1,
                       'text/plain','Attachments/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.txt','now'
                     );",
                )
                .unwrap();
        }

        assert!(Store::open(&path).is_err());
        {
            let connection = Connection::open(&path).unwrap();
            assert!(table_exists(&connection, "task_session").unwrap());
            assert!(!table_exists(&connection, "terminal_session").unwrap());
            assert_eq!(database_schema_version(&connection).unwrap(), Some(4));
            connection
                .execute("DELETE FROM task_attachment", [])
                .unwrap();
        }
        assert_eq!(
            Store::open(&path).unwrap().health().unwrap()["schemaVersion"],
            5
        );
    }

    #[test]
    fn v5_checksum_mismatch_fails_closed() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("todoagent.sqlite3");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch(include_str!("schema.sql"))
                .unwrap();
            connection
                .execute(
                    "INSERT INTO schema_migration(version,name,checksum,applied_at)
                     VALUES(5,'terminal sessions','wrong','now')",
                    [],
                )
                .unwrap();
        }
        assert!(matches!(Store::open(&path), Err(StoreError::Invalid(_))));
    }

    #[test]
    fn runtime_detection_preserves_verified_state_when_paths_are_unchanged() {
        for status in ["ready", "auth_required", "error"] {
            let directory = tempdir().unwrap();
            let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
            let verified = runtime_record(
                status,
                Some("/usr/local/bin/codex"),
                Some("/opt/codex/bin/codex"),
                Some("2026-08-09T00:01:00Z"),
            );
            store.save_runtime(&verified).unwrap();

            let mut detected = runtime_record(
                "detected",
                Some("/usr/local/bin/codex"),
                Some("/opt/codex/bin/codex"),
                None,
            );
            detected.version = None;
            detected.auth_status = "unknown".to_owned();
            detected.verify_error = None;
            detected.detected_at = Some("2026-08-09T00:02:00Z".to_owned());
            detected.capabilities = json!({"nativeResume": true, "text": true});

            let saved = store.save_detected_runtime(&detected).unwrap();
            assert_eq!(saved.status, status);
            assert_eq!(saved.version.as_deref(), Some("codex-cli 1.2.3"));
            assert_eq!(
                saved.auth_status,
                if status == "ready" {
                    "authenticated"
                } else {
                    "required"
                }
            );
            assert_eq!(
                saved.verify_error.as_deref(),
                (status != "ready").then_some("saved verification")
            );
            assert_eq!(saved.verified_at.as_deref(), Some("2026-08-09T00:01:00Z"));
            assert_eq!(saved.detected_at.as_deref(), Some("2026-08-09T00:02:00Z"));
            assert_eq!(saved.capabilities["text"], true);
            assert_eq!(store.runtime(RuntimeKind::Codex).unwrap(), Some(saved));
        }
    }

    #[test]
    fn runtime_detection_resets_verification_when_launch_or_resolved_path_changes() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let verified = runtime_record(
            "ready",
            Some("/usr/local/bin/codex"),
            Some("/opt/codex-v1/bin/codex"),
            Some("2026-08-09T00:01:00Z"),
        );
        store.save_runtime(&verified).unwrap();

        let mut moved = runtime_record(
            "detected",
            Some("/usr/local/bin/codex"),
            Some("/opt/codex-v2/bin/codex"),
            None,
        );
        moved.version = None;
        moved.auth_status = "unknown".to_owned();
        moved.verify_error = None;

        let saved = store.save_detected_runtime(&moved).unwrap();
        assert_eq!(saved.status, "detected");
        assert_eq!(saved.verified_at, None);
        assert_eq!(saved.version, None);
        assert_eq!(store.runtime(RuntimeKind::Codex).unwrap(), Some(moved));
    }

    #[test]
    fn bootstrap_visible_runtime_mutations_advance_revision_once() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let codex = runtime_record(
            "detected",
            Some("/usr/local/bin/codex"),
            Some("/opt/codex/bin/codex"),
            None,
        );
        let mut claude = runtime_record(
            "detected",
            Some("/usr/local/bin/claude"),
            Some("/opt/claude/bin/claude"),
            None,
        );
        claude.kind = RuntimeKind::Claude;
        let initial_revision = store.revision().unwrap();

        let persisted = store
            .save_detected_runtimes(&[codex.clone(), claude])
            .unwrap();

        assert_eq!(persisted.len(), 2);
        assert_eq!(store.revision().unwrap(), initial_revision + 1);
        let mut verified = codex;
        verified.status = "ready".to_owned();
        verified.auth_status = "authenticated".to_owned();
        verified.verified_at = Some("2026-08-09T00:03:00Z".to_owned());
        store.save_runtime(&verified).unwrap();
        assert_eq!(store.revision().unwrap(), initial_revision + 2);
        assert_eq!(store.bootstrap().unwrap().runtimes.len(), 2);
    }
    #[test]
    fn task_dates_are_strict_distinct_and_patch_dates_are_tri_state() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let list = store.create_list("日期测试", "blue", None).unwrap();
        let task = store
            .create_task(
                "  安排演示  ",
                "备注",
                Some(&list.id.to_uppercase()),
                Some("2026-08-12"),
                Some("2026-08-10"),
            )
            .unwrap();
        assert_eq!(task.title, "安排演示");
        assert_eq!(task.list_id.as_deref(), Some(list.id.as_str()));
        assert_eq!(task.execution_date.as_deref(), Some("2026-08-12"));
        assert_eq!(task.due_date.as_deref(), Some("2026-08-10"));

        let missing: UpdateTaskInput = serde_json::from_value(json!({})).unwrap();
        assert_eq!(missing.list_id, None);
        assert_eq!(missing.execution_date, None);
        assert_eq!(missing.due_date, None);
        let explicit_null: UpdateTaskInput = serde_json::from_value(json!({
            "listId": null,
            "executionDate": null,
            "dueDate": null
        }))
        .unwrap();
        assert_eq!(explicit_null.list_id, Some(None));
        assert_eq!(explicit_null.execution_date, Some(None));
        assert_eq!(explicit_null.due_date, Some(None));
        let set_value: UpdateTaskInput = serde_json::from_value(json!({
            "listId": list.id.to_uppercase(),
            "executionDate": "2026-08-15",
            "dueDate": "2026-08-16"
        }))
        .unwrap();
        assert_eq!(set_value.list_id, Some(Some(list.id.clone())));
        assert_eq!(
            set_value.execution_date,
            Some(Some("2026-08-15".to_owned()))
        );

        let cleared = store
            .update_task(
                &task.id,
                &UpdateTaskInput {
                    due_date: Some(None),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(cleared.execution_date.as_deref(), Some("2026-08-12"));
        assert_eq!(cleared.due_date, None);

        for invalid in [
            "0000-01-01",
            "2026-8-9",
            "2026-02-30",
            "2026-08-09T00:00:00Z",
        ] {
            assert!(matches!(
                store.create_task("错误日期", "", None, Some(invalid), None),
                Err(StoreError::Invalid(_))
            ));
        }
        assert!(matches!(
            store.update_task(
                &task.id.to_uppercase(),
                &UpdateTaskInput {
                    execution_date: Some(Some("0000-01-01".to_owned())),
                    ..Default::default()
                },
            ),
            Err(StoreError::Invalid(_))
        ));
        assert!(store
            .connection
            .execute(
                "INSERT INTO task(id,list_id,title,note,status,execution_date,due_date,created_at,updated_at)
                 VALUES(?1,NULL,'schema boundary','', 'open','0000-01-01',NULL,'now','now')",
                [Uuid::new_v4().to_string()],
            )
            .is_err());
    }

    #[test]
    fn task_attachment_metadata_is_in_bootstrap_and_removes_only_requested_copy() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("附件任务", "", None, None, None).unwrap();
        let initial_revision = store.revision().unwrap();
        let first_id = Uuid::new_v4().to_string();
        let first = TaskAttachment {
            id: first_id.clone(),
            task_id: task.id.clone(),
            original_name: "brief.pdf".to_owned(),
            size_bytes: 42,
            mime_type: "application/pdf".to_owned(),
            relative_path: format!("Attachments/{first_id}.pdf"),
            created_at: now(),
        };
        let second_id = Uuid::new_v4().to_string();
        let second = TaskAttachment {
            id: second_id.clone(),
            task_id: task.id.clone(),
            original_name: "brief.pdf".to_owned(),
            size_bytes: 43,
            mime_type: "application/pdf".to_owned(),
            relative_path: format!("Attachments/{second_id}.pdf"),
            created_at: now(),
        };

        store
            .add_task_attachments(&task.id, &[first.clone(), second.clone()])
            .unwrap();
        let snapshot = store.bootstrap().unwrap();
        assert_eq!(
            snapshot.task_attachments,
            vec![first.clone(), second.clone()]
        );
        assert_eq!(snapshot.revision, initial_revision + 1);

        let removed = store.remove_task_attachment(&task.id, &first.id).unwrap();
        assert_eq!(removed, first);
        assert_eq!(store.bootstrap().unwrap().task_attachments, vec![second]);
    }

    #[test]
    fn task_attachment_mutation_receipts_are_durable_and_reject_key_reuse() {
        let directory = tempdir().unwrap();
        let database = directory.path().join("todoagent.sqlite3");
        let store = Store::open(&database).unwrap();
        let task = store.create_task("附件幂等", "", None, None, None).unwrap();
        let source_paths = vec!["/tmp/brief.pdf".to_owned()];
        let add_mutation_id = Uuid::new_v4().to_string();
        let attachment_id = Uuid::new_v4().to_string();
        let attachment = TaskAttachment {
            id: attachment_id.clone(),
            task_id: task.id.clone(),
            original_name: "brief.pdf".to_owned(),
            size_bytes: 42,
            mime_type: "application/pdf".to_owned(),
            relative_path: format!("Attachments/{attachment_id}.pdf"),
            created_at: now(),
        };

        assert!(
            !store
                .prepare_add_task_attachment_mutation(
                    &task.id.to_uppercase(),
                    &add_mutation_id.to_uppercase(),
                    &source_paths,
                )
                .unwrap()
        );
        let revision_before_add = store.revision().unwrap();
        assert_eq!(
            store
                .add_task_attachments_idempotent(
                    &task.id,
                    &add_mutation_id,
                    &source_paths,
                    std::slice::from_ref(&attachment),
                )
                .unwrap(),
            AttachmentMutationOutcome::Applied
        );
        let revision_after_add = store.revision().unwrap();
        assert_eq!(revision_after_add, revision_before_add + 1);

        let duplicate_id = Uuid::new_v4().to_string();
        let duplicate = TaskAttachment {
            id: duplicate_id.clone(),
            relative_path: format!("Attachments/{duplicate_id}.pdf"),
            ..attachment.clone()
        };
        assert_eq!(
            store
                .add_task_attachments_idempotent(
                    &task.id,
                    &add_mutation_id,
                    &source_paths,
                    &[duplicate],
                )
                .unwrap(),
            AttachmentMutationOutcome::Replayed
        );
        assert_eq!(store.revision().unwrap(), revision_after_add);
        assert_eq!(
            store.bootstrap().unwrap().task_attachments,
            vec![attachment.clone()]
        );
        let stored_result: String = store
            .connection
            .query_row(
                "SELECT result_attachment_ids_json FROM task_attachment_mutation
                 WHERE client_mutation_id=?1",
                [&add_mutation_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(stored_result, json!([attachment_id]).to_string());
        assert!(matches!(
            store.prepare_add_task_attachment_mutation(
                &task.id,
                &add_mutation_id,
                &["/tmp/different.pdf".to_owned()],
            ),
            Err(StoreError::Conflict("attachment_mutation_conflict"))
        ));
        assert!(matches!(
            store.prepare_remove_task_attachment_mutation(
                &task.id,
                &attachment.id,
                &add_mutation_id,
            ),
            Err(StoreError::Conflict("attachment_mutation_conflict"))
        ));

        drop(store);
        let store = Store::open(&database).unwrap();
        assert!(
            store
                .prepare_add_task_attachment_mutation(&task.id, &add_mutation_id, &source_paths,)
                .unwrap()
        );

        let remove_mutation_id = Uuid::new_v4().to_string();
        assert_eq!(
            store
                .prepare_remove_task_attachment_mutation(
                    &task.id.to_uppercase(),
                    &attachment.id.to_uppercase(),
                    &remove_mutation_id.to_uppercase(),
                )
                .unwrap(),
            RemoveTaskAttachmentPreparation::Pending(attachment.clone())
        );
        let revision_before_remove = store.revision().unwrap();
        assert_eq!(
            store
                .remove_task_attachment_idempotent(&task.id, &attachment.id, &remove_mutation_id,)
                .unwrap(),
            AttachmentMutationOutcome::Applied
        );
        let revision_after_remove = store.revision().unwrap();
        assert_eq!(revision_after_remove, revision_before_remove + 1);
        assert_eq!(
            store
                .prepare_remove_task_attachment_mutation(
                    &task.id,
                    &attachment.id,
                    &remove_mutation_id,
                )
                .unwrap(),
            RemoveTaskAttachmentPreparation::Replayed
        );
        assert_eq!(
            store
                .remove_task_attachment_idempotent(&task.id, &attachment.id, &remove_mutation_id,)
                .unwrap(),
            AttachmentMutationOutcome::Replayed
        );
        assert_eq!(store.revision().unwrap(), revision_after_remove);
        assert!(matches!(
            store.prepare_remove_task_attachment_mutation(
                &task.id,
                &attachment.id,
                &Uuid::new_v4().to_string(),
            ),
            Err(StoreError::NotFound)
        ));
    }

    #[test]
    fn attachment_reconciliation_cleans_staging_and_add_crash_orphans() {
        let directory = tempdir().unwrap();
        let attachments = directory.path().join("Attachments");
        fs::create_dir_all(&attachments).unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("附件恢复", "", None, None, None).unwrap();
        let referenced_id = Uuid::new_v4().to_string();
        let referenced_name = format!("{referenced_id}.txt");
        let referenced = TaskAttachment {
            id: referenced_id,
            task_id: task.id.clone(),
            original_name: "keep.txt".to_owned(),
            size_bytes: 4,
            mime_type: "text/plain".to_owned(),
            relative_path: format!("Attachments/{referenced_name}"),
            created_at: now(),
        };
        store
            .add_task_attachments(&task.id, std::slice::from_ref(&referenced))
            .unwrap();
        fs::write(attachments.join(&referenced_name), b"keep").unwrap();
        fs::write(attachments.join(".staging-abandoned"), b"partial").unwrap();
        fs::write(
            attachments.join(format!("{}.pdf", Uuid::new_v4())),
            b"orphan",
        )
        .unwrap();
        let external = directory.path().join("credentials.json");
        fs::write(&external, b"credential").unwrap();
        let orphan_link = attachments.join("orphan-link");
        symlink(&external, &orphan_link).unwrap();

        store.reconcile_task_attachment_files(&attachments).unwrap();

        assert_eq!(
            fs::read(attachments.join(referenced_name)).unwrap(),
            b"keep"
        );
        assert_eq!(fs::read_dir(&attachments).unwrap().count(), 1);
        assert_eq!(fs::read(external).unwrap(), b"credential");
        assert!(!orphan_link.exists());
    }

    #[test]
    fn attachment_reconciliation_restores_remove_before_database_commit() {
        let directory = tempdir().unwrap();
        let attachments = directory.path().join("Attachments");
        fs::create_dir_all(&attachments).unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("恢复移除", "", None, None, None).unwrap();
        let attachment_id = Uuid::new_v4().to_string();
        let final_name = format!("{attachment_id}.txt");
        let attachment = TaskAttachment {
            id: attachment_id.clone(),
            task_id: task.id.clone(),
            original_name: "restore.txt".to_owned(),
            size_bytes: 7,
            mime_type: "text/plain".to_owned(),
            relative_path: format!("Attachments/{final_name}"),
            created_at: now(),
        };
        store.add_task_attachments(&task.id, &[attachment]).unwrap();
        let final_path = attachments.join(&final_name);
        let quarantine = attachments.join(format!(".removing-{attachment_id}"));
        fs::write(&final_path, b"restore").unwrap();
        fs::rename(&final_path, &quarantine).unwrap();

        store.reconcile_task_attachment_files(&attachments).unwrap();

        assert_eq!(fs::read(final_path).unwrap(), b"restore");
        assert!(!quarantine.exists());
        assert!(
            store
                .task_attachment(&task.id, &attachment_id)
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn attachment_reconciliation_deletes_remove_after_database_commit() {
        let directory = tempdir().unwrap();
        let attachments = directory.path().join("Attachments");
        fs::create_dir_all(&attachments).unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("完成移除", "", None, None, None).unwrap();
        let attachment_id = Uuid::new_v4().to_string();
        let final_name = format!("{attachment_id}.txt");
        let attachment = TaskAttachment {
            id: attachment_id.clone(),
            task_id: task.id.clone(),
            original_name: "remove.txt".to_owned(),
            size_bytes: 6,
            mime_type: "text/plain".to_owned(),
            relative_path: format!("Attachments/{final_name}"),
            created_at: now(),
        };
        store.add_task_attachments(&task.id, &[attachment]).unwrap();
        let quarantine = attachments.join(format!(".removing-{attachment_id}"));
        fs::write(&quarantine, b"remove").unwrap();
        store
            .remove_task_attachment(&task.id, &attachment_id)
            .unwrap();

        store.reconcile_task_attachment_files(&attachments).unwrap();

        assert!(!quarantine.exists());
        assert_eq!(fs::read_dir(attachments).unwrap().count(), 0);
    }

    #[test]
    fn assistant_turn_receipt_is_idempotent_and_task_mutation_is_atomic() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("").unwrap();
        let client_id = Uuid::new_v4().to_string();
        let queued = store
            .begin_assistant_turn(&session.id, &client_id, "新增任务", None, Some("model-x"))
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        let result = store
            .execute_assistant_tool(
                &queued.turn.id,
                "call-1",
                "create_tasks",
                r#"{"tasks":[{"title":"只创建一次"}]}"#,
            )
            .unwrap();
        let duplicate = store
            .execute_assistant_tool(
                &queued.turn.id,
                "call-1",
                "create_tasks",
                r#"{"tasks":[{"title":"不应创建"}]}"#,
            )
            .unwrap();
        assert_eq!(result, duplicate);
        assert_eq!(store.tasks().unwrap().len(), 1);

        let missing_list_id = Uuid::new_v4().to_string();
        let failure = store.execute_assistant_tool(
            &queued.turn.id,
            "call-2",
            "create_tasks",
            &json!({
                "tasks":[
                    {"title":"会回滚"},
                    {"title":"无效清单","listId":missing_list_id}
                ]
            })
            .to_string(),
        );
        assert!(matches!(failure, Err(StoreError::NotFound)));
        assert_eq!(store.tasks().unwrap().len(), 1);
    }

    #[test]
    fn assistant_delete_task_is_atomic_idempotent_and_keeps_deleted_refs_empty() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store
            .create_task("删除一次", "保留删除摘要", None, None, None)
            .unwrap();
        let attachment_id = Uuid::new_v4().to_string();
        let attachment = TaskAttachment {
            id: attachment_id.clone(),
            task_id: task.id.clone(),
            original_name: "memo.txt".to_owned(),
            size_bytes: 4,
            mime_type: "text/plain".to_owned(),
            relative_path: format!("Attachments/{attachment_id}.txt"),
            created_at: now(),
        };
        store
            .add_task_attachments(&task.id, std::slice::from_ref(&attachment))
            .unwrap();
        let queued = running_assistant_turn(&store, "删除任务");
        let arguments = json!({"taskId":task.id.to_uppercase()}).to_string();
        let prepared = store
            .prepare_delete_task(&task.id)
            .unwrap()
            .into_iter()
            .map(|attachment| (attachment.id, attachment.relative_path))
            .collect::<Vec<_>>();
        let app_revision = store.revision().unwrap();
        let task_revision: i64 = store
            .connection
            .query_row(
                "SELECT revision FROM task_data_revision WHERE singleton=1",
                [],
                |row| row.get(0),
            )
            .unwrap();

        let first = store
            .execute_assistant_delete_task(
                &queued.turn.id,
                "delete-once",
                &task.id,
                &prepared,
                &arguments,
            )
            .unwrap();
        let first = match first {
            AssistantDeleteTaskOutcome::Applied(result) => result,
            AssistantDeleteTaskOutcome::Replayed(_) => panic!("first delete must apply"),
        };
        let result = serde_json::from_str::<Value>(&first.result_json).unwrap();
        assert_eq!(result["deletedTask"]["id"], task.id);
        assert_eq!(result["deletedTask"]["title"], "删除一次");
        assert_eq!(first.task_refs_json, "[]");
        assert!(store.task(&task.id).unwrap().is_none());
        assert!(store.bootstrap().unwrap().task_attachments.is_empty());
        assert_eq!(store.revision().unwrap(), app_revision + 1);
        assert_eq!(
            store
                .connection
                .query_row(
                    "SELECT revision FROM task_data_revision WHERE singleton=1",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            task_revision + 1
        );
        let receipt = store
            .assistant_tool_execution(&queued.turn.session_id, "delete-once")
            .unwrap()
            .unwrap();
        assert_eq!(receipt.tool_name, "delete_task");
        assert_eq!(receipt.task_refs_json.as_deref(), Some("[]"));

        let replay_revision = store.revision().unwrap();
        let replay = store
            .execute_assistant_delete_task(
                &queued.turn.id,
                "delete-once",
                &task.id,
                &prepared,
                &arguments,
            )
            .unwrap();
        match replay {
            AssistantDeleteTaskOutcome::Replayed(result) => assert_eq!(result, first),
            AssistantDeleteTaskOutcome::Applied(_) => panic!("replay must not delete twice"),
        }
        assert_eq!(store.revision().unwrap(), replay_revision);

        let other = store
            .create_task("不能复用 callId", "", None, None, None)
            .unwrap();
        let mismatch = store.execute_assistant_delete_task(
            &queued.turn.id,
            "delete-once",
            &other.id,
            &[],
            &json!({"taskId":other.id}).to_string(),
        );
        assert!(matches!(
            mismatch,
            Err(StoreError::Conflict("assistant_tool_call_mismatch"))
        ));
        assert!(store.task(&other.id).unwrap().is_some());
    }

    #[test]
    fn assistant_delete_task_rechecks_active_sessions_and_attachment_manifest() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let active_task = store
            .create_task("运行中不能删除", "", None, None, None)
            .unwrap();
        let task_session = store
            .create_terminal_session(&active_task.id, RuntimeKind::Codex, "/tmp")
            .unwrap();
        store
            .prepare_terminal_run(&task_session.id, &Uuid::new_v4().to_string())
            .unwrap();
        let queued = running_assistant_turn(&store, "安全删除");
        let active_result = store.execute_assistant_delete_task(
            &queued.turn.id,
            "delete-active",
            &active_task.id,
            &[],
            &json!({"taskId":active_task.id}).to_string(),
        );
        assert!(matches!(
            active_result,
            Err(StoreError::Conflict("task_session_active"))
        ));
        assert!(store.task(&active_task.id).unwrap().is_some());
        assert!(
            store
                .assistant_tool_execution(&queued.turn.session_id, "delete-active")
                .unwrap()
                .is_none()
        );

        let changed_task = store
            .create_task("附件变化不能删除", "", None, None, None)
            .unwrap();
        let first_id = Uuid::new_v4().to_string();
        let first = TaskAttachment {
            id: first_id.clone(),
            task_id: changed_task.id.clone(),
            original_name: "first.txt".to_owned(),
            size_bytes: 1,
            mime_type: "text/plain".to_owned(),
            relative_path: format!("Attachments/{first_id}.txt"),
            created_at: now(),
        };
        store
            .add_task_attachments(&changed_task.id, std::slice::from_ref(&first))
            .unwrap();
        let prepared = vec![(first.id.clone(), first.relative_path.clone())];
        let second_id = Uuid::new_v4().to_string();
        store
            .add_task_attachments(
                &changed_task.id,
                &[TaskAttachment {
                    id: second_id.clone(),
                    task_id: changed_task.id.clone(),
                    original_name: "second.txt".to_owned(),
                    size_bytes: 1,
                    mime_type: "text/plain".to_owned(),
                    relative_path: format!("Attachments/{second_id}.txt"),
                    created_at: now(),
                }],
            )
            .unwrap();
        let changed_result = store.execute_assistant_delete_task(
            &queued.turn.id,
            "delete-changed",
            &changed_task.id,
            &prepared,
            &json!({"taskId":changed_task.id}).to_string(),
        );
        assert!(matches!(
            changed_result,
            Err(StoreError::Conflict("task_attachments_changed"))
        ));
        assert!(store.task(&changed_task.id).unwrap().is_some());
        assert!(
            store
                .assistant_tool_execution(&queued.turn.session_id, "delete-changed")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn assistant_update_task_can_set_and_clear_both_dates_and_list() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let list = store.create_list("工作", "blue", None).unwrap();
        let task = store
            .create_task(
                "待调整",
                "",
                Some(&list.id),
                Some("2026-08-10"),
                Some("2026-08-12"),
            )
            .unwrap();
        let session = store.create_assistant_session("更新任务").unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "清除任务归属和日期",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();

        store
            .execute_assistant_tool(
                &queued.turn.id,
                "clear-fields",
                "update_task",
                &json!({
                    "taskId": task.id,
                    "title": "已调整",
                    "executionDate": "2026-08-11",
                    "dueDate": ""
                })
                .to_string(),
            )
            .unwrap();

        let updated = store.task(&task.id).unwrap().unwrap();
        assert_eq!(updated.title, "已调整");
        assert_eq!(updated.list_id.as_deref(), Some(list.id.as_str()));
        assert_eq!(updated.execution_date.as_deref(), Some("2026-08-11"));
        assert_eq!(updated.due_date, None);

        store
            .execute_assistant_tool(
                &queued.turn.id,
                "legacy-nested-clear",
                "update_task",
                &json!({
                    "taskId": task.id,
                    "update": {"listId": null, "executionDate": null, "dueDate": null}
                })
                .to_string(),
            )
            .unwrap();
        let updated = store.task(&task.id).unwrap().unwrap();
        assert_eq!(updated.list_id, None);
        assert_eq!(updated.execution_date, None);
        assert_eq!(updated.due_date, None);
    }

    #[test]
    fn assistant_non_delete_task_tools_execute_happy_paths() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let list = store.create_list("生活", "orange", None).unwrap();
        let queued = running_assistant_turn(&store, "非删除工具");

        let created = store
            .execute_assistant_tool(
                &queued.turn.id,
                "create-two",
                "create_tasks",
                &json!({
                    "tasks": [
                        {"title":"晨间健身","note":"跑步三十分钟","listId":list.id.to_uppercase(),"executionDate":"2026-08-10","dueDate":"2026-08-12"},
                        {"title":"采购牛奶"}
                    ]
                })
                .to_string(),
            )
            .unwrap();
        let task_refs = serde_json::from_str::<Vec<String>>(&created.task_refs_json).unwrap();
        assert_eq!(task_refs.len(), 2);
        assert_eq!(
            store
                .task(&task_refs[0])
                .unwrap()
                .unwrap()
                .list_id
                .as_deref(),
            Some(list.id.as_str())
        );

        let found = store
            .execute_assistant_tool(
                &queued.turn.id,
                "find-two",
                "find_related",
                r#"{"query":"健身 牛奶"}"#,
            )
            .unwrap();
        let found_value = serde_json::from_str::<Value>(&found.result_json).unwrap();
        assert_eq!(found_value["tasks"].as_array().unwrap().len(), 2);
        let fitness = found_value["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|task| task["title"] == "晨间健身")
            .unwrap();
        assert_eq!(fitness["executionDate"], "2026-08-10");
        assert_eq!(fitness["dueDate"], "2026-08-12");
        assert_eq!(found.task_refs_json, "[]");

        store
            .execute_assistant_tool(
                &queued.turn.id,
                "update-one",
                "update_task",
                &json!({
                    "taskId":task_refs[0].to_uppercase(),
                    "title":"晚上健身",
                    "listId":list.id.to_uppercase(),
                    "executionDate":"",
                    "dueDate":""
                })
                .to_string(),
            )
            .unwrap();
        let updated = store.task(&task_refs[0]).unwrap().unwrap();
        assert_eq!(updated.title, "晚上健身");
        assert_eq!(updated.list_id.as_deref(), Some(list.id.as_str()));
        assert_eq!(updated.execution_date, None);
        assert_eq!(updated.due_date, None);

        let invalid_agent_create = store.execute_assistant_tool(
            &queued.turn.id,
            "invalid-year-create",
            "create_tasks",
            r#"{"tasks":[{"title":"错误年份","executionDate":"0000-01-01"}]}"#,
        );
        assert!(matches!(invalid_agent_create, Err(StoreError::Invalid(_))));
        let invalid_agent_update = store.execute_assistant_tool(
            &queued.turn.id,
            "invalid-year-update",
            "update_task",
            &json!({
                "taskId": task_refs[0].to_uppercase(),
                "dueDate": "0000-12-31"
            })
            .to_string(),
        );
        assert!(matches!(invalid_agent_update, Err(StoreError::Invalid(_))));

        let lists = store
            .execute_assistant_tool(&queued.turn.id, "list-lists", "list_lists", "{}")
            .unwrap();
        let lists_value = serde_json::from_str::<Value>(&lists.result_json).unwrap();
        assert_eq!(lists_value["lists"][0]["id"], list.id);

        let filtered = store
            .execute_assistant_tool(
                &queued.turn.id,
                "uppercase-list-filter",
                "list_state",
                &json!({"listId":list.id.to_uppercase()}).to_string(),
            )
            .unwrap();
        let filtered_value = serde_json::from_str::<Value>(&filtered.result_json).unwrap();
        assert_eq!(filtered_value["pagination"]["total"], 1);
        assert_eq!(filtered_value["filters"]["listId"], list.id);

        store
            .set_task_status(&task_refs[1], TaskStatus::Completed)
            .unwrap();
        let state = store
            .execute_assistant_tool(&queued.turn.id, "list-state", "list_state", "{}")
            .unwrap();
        let state_value = serde_json::from_str::<Value>(&state.result_json).unwrap();
        assert_eq!(state_value["counts"]["open"], 1);
        assert_eq!(state_value["counts"]["completed"], 1);
        assert_eq!(state_value["counts"]["runningOrQueuedSessions"], 0);
        assert_eq!(state_value["counts"]["unreadSessions"], 0);
    }

    #[test]
    fn assistant_tool_arguments_reject_missing_wrong_and_unknown_fields() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("待更新", "", None, None, None).unwrap();
        let queued = running_assistant_turn(&store, "参数校验");
        let invalid_calls = vec![
            (
                "create_tasks",
                json!({"tasks":[{"title":"任务","extra":true}]}),
            ),
            (
                "create_tasks",
                json!({"tasks":[{"title":"任务"}],"extra":true}),
            ),
            ("create_tasks", json!({"tasks":"not-an-array"})),
            ("find_related", json!({})),
            ("find_related", json!({"query":""})),
            ("find_related", json!({"query":42})),
            ("find_related", json!({"query":"x".repeat(201)})),
            ("find_related", json!({"query":"任务","limit":1})),
            ("list_state", json!({"extra":true})),
            (
                "list_state",
                json!({"executionDate":"2026-08-10","pageSize":0}),
            ),
            (
                "list_state",
                json!({"executionDate":"2026-08-10","pageSize":51}),
            ),
            (
                "list_state",
                json!({
                    "cursor":{
                        "status":"open",
                        "updatedAt":"2026-08-09T00:00:00Z",
                        "taskId":task.id
                    }
                }),
            ),
            ("list_lists", json!([])),
            (
                "update_task",
                json!({"taskId":task.id,"title":"扁平","update":{"note":"嵌套"}}),
            ),
            (
                "update_task",
                json!({"taskId":task.id,"status":"completed"}),
            ),
            ("update_task", json!({"taskId":42,"title":"错误"})),
            ("update_task", json!({"taskId":task.id,"title":42})),
            (
                "update_task",
                json!({"taskId":task.id,"update":{"unknown":true}}),
            ),
        ];

        for (index, (name, arguments)) in invalid_calls.into_iter().enumerate() {
            let result = store.execute_assistant_tool(
                &queued.turn.id,
                &format!("invalid-{index}"),
                name,
                &arguments.to_string(),
            );
            assert!(
                matches!(result, Err(StoreError::Invalid(_))),
                "{name} unexpectedly accepted {arguments}: {result:?}"
            );
        }
        assert_eq!(store.tasks().unwrap().len(), 1);
    }

    #[test]
    fn assistant_list_state_counts_are_exact_beyond_summary_limits() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let mut open_tasks = Vec::new();
        for index in 0..25 {
            open_tasks.push(
                store
                    .create_task(&format!("待办 {index}"), "", None, None, None)
                    .unwrap(),
            );
        }
        for index in 0..3 {
            let task = store
                .create_task(&format!("完成 {index}"), "", None, None, None)
                .unwrap();
            store
                .set_task_status(&task.id, TaskStatus::Completed)
                .unwrap();
        }
        let timestamp = now();
        store
            .connection
            .execute(
                "INSERT INTO terminal_session(id,task_id,runtime_kind,working_directory,agent_status,status_sequence,seen_status_sequence,created_at,updated_at)
                 VALUES(?1,?2,'codex','/tmp','blocked',3,1,?3,?3)",
                params![Uuid::new_v4().to_string(), open_tasks[0].id, timestamp],
            )
            .unwrap();
        let summary_session = store
            .terminal_session_for_task(&open_tasks[0].id)
            .unwrap()
            .unwrap();
        store
            .prepare_terminal_run(&summary_session.id, &Uuid::new_v4().to_string())
            .unwrap();
        let queued = running_assistant_turn(&store, "精确计数");
        let state = store
            .execute_assistant_tool(&queued.turn.id, "count-state", "list_state", "{}")
            .unwrap();
        let value = serde_json::from_str::<Value>(&state.result_json).unwrap();

        assert_eq!(value["counts"]["open"], 25);
        assert_eq!(value["counts"]["completed"], 3);
        assert_eq!(value["counts"]["runningOrQueuedSessions"], 1);
        assert_eq!(value["counts"]["unreadSessions"], 1);
        assert_eq!(value["tasks"]["open"].as_array().unwrap().len(), 25);
        assert_eq!(value["tasks"]["completed"].as_array().unwrap().len(), 3);
        assert_eq!(value["truncated"], false);
    }

    #[test]
    fn assistant_list_state_execution_date_filter_returns_more_than_old_twenty_row_limit() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        for index in 0..25 {
            store
                .create_task(
                    &format!("八月十日任务 {index}"),
                    "",
                    None,
                    Some("2026-08-10"),
                    None,
                )
                .unwrap();
        }
        store
            .create_task("只有截止日期", "", None, None, Some("2026-08-10"))
            .unwrap();
        store
            .create_task("另一天执行", "", None, Some("2026-08-11"), None)
            .unwrap();
        let queued = running_assistant_turn(&store, "查询当天");

        let state = store
            .execute_assistant_tool(
                &queued.turn.id,
                "filtered-state",
                "list_state",
                &json!({"executionDate":"2026-08-10","status":"open"}).to_string(),
            )
            .unwrap();
        let value = serde_json::from_str::<Value>(&state.result_json).unwrap();

        assert_eq!(value["counts"]["open"], 25);
        assert_eq!(value["counts"]["completed"], 0);
        let tasks = value["tasks"]["open"].as_array().unwrap();
        assert_eq!(tasks.len(), 25);
        assert!(
            tasks
                .iter()
                .all(|task| task["executionDate"] == "2026-08-10")
        );
        assert_eq!(value["truncated"], false);
    }

    #[test]
    fn assistant_filtered_list_state_cursor_traverses_over_fifty_and_eight_kib() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let long_title_suffix = "标题".repeat(240);
        let long_note = "备注".repeat(1_900);
        for index in 0..73 {
            store
                .create_task(
                    &format!("{index:03}-{long_title_suffix}"),
                    &long_note,
                    None,
                    Some("2026-08-10"),
                    Some("2026-08-31"),
                )
                .unwrap();
        }
        let queued = running_assistant_turn(&store, "分页查询全天任务");
        let mut cursor = None;
        let mut ids = HashSet::new();
        let mut pages = 0usize;
        let mut task_revision = None;

        loop {
            let mut arguments = json!({
                "executionDate":"2026-08-10",
                "status":"open",
                "pageSize":50
            });
            if let Some(cursor) = cursor.take() {
                arguments
                    .as_object_mut()
                    .unwrap()
                    .insert("cursor".to_owned(), cursor);
            }
            let result = store
                .execute_assistant_tool(
                    &queued.turn.id,
                    &format!("page-{pages}"),
                    "list_state",
                    &arguments.to_string(),
                )
                .unwrap();
            assert!(result.result_json.len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES);
            let value = serde_json::from_str::<Value>(&result.result_json).unwrap();
            assert_eq!(value["pagination"]["total"], 73);
            assert!(value["pagination"]["returned"].as_u64().unwrap() > 0);
            let page_task_revision = value["taskRevision"].as_i64().unwrap();
            assert_eq!(value["pagination"]["taskRevision"], page_task_revision);
            assert_eq!(
                *task_revision.get_or_insert(page_task_revision),
                page_task_revision
            );
            for task in value["tasks"]["open"].as_array().unwrap() {
                assert_eq!(task["executionDate"], "2026-08-10");
                assert!(ids.insert(task["id"].as_str().unwrap().to_owned()));
            }
            pages += 1;
            if value["pagination"]["hasMore"] == false {
                assert!(value["pagination"]["nextCursor"].is_null());
                break;
            }
            let mut next_cursor = value["pagination"]["nextCursor"].clone();
            assert!(next_cursor.is_object());
            let uppercase_task_id = next_cursor["taskId"].as_str().unwrap().to_uppercase();
            next_cursor["taskId"] = Value::String(uppercase_task_id);
            cursor = Some(next_cursor);
        }

        assert!(pages >= 2);
        assert_eq!(ids.len(), 73);
    }

    #[test]
    fn assistant_filtered_list_state_rejects_cursor_with_changed_filters() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        for index in 0..2 {
            store
                .create_task(&format!("任务 {index}"), "", None, Some("2026-08-10"), None)
                .unwrap();
        }
        let queued = running_assistant_turn(&store, "游标过滤校验");
        let first = store
            .execute_assistant_tool(
                &queued.turn.id,
                "cursor-first",
                "list_state",
                &json!({
                    "executionDate":"2026-08-10",
                    "status":"open",
                    "pageSize":1
                })
                .to_string(),
            )
            .unwrap();
        let first = serde_json::from_str::<Value>(&first.result_json).unwrap();
        let cursor = first["pagination"]["nextCursor"].clone();

        let error = store.execute_assistant_tool(
            &queued.turn.id,
            "cursor-mismatch",
            "list_state",
            &json!({
                "executionDate":"2026-08-11",
                "status":"open",
                "cursor":cursor
            })
            .to_string(),
        );

        assert!(matches!(error, Err(StoreError::Invalid(_))));

        let status_cursor = first_filtered_cursor(&store, &queued, "cursor-status-first");
        let mut status_cursor = status_cursor;
        status_cursor["status"] = Value::String("completed".to_owned());
        let error = store.execute_assistant_tool(
            &queued.turn.id,
            "cursor-status-mismatch",
            "list_state",
            &json!({
                "executionDate":"2026-08-10",
                "status":"open",
                "cursor":status_cursor
            })
            .to_string(),
        );
        assert!(matches!(error, Err(StoreError::Invalid(_))));

        let mut key_cursor = first_filtered_cursor(&store, &queued, "cursor-key-first");
        key_cursor["taskId"] = Value::String(Uuid::new_v4().to_string());
        let error = store.execute_assistant_tool(
            &queued.turn.id,
            "cursor-key-mismatch",
            "list_state",
            &json!({
                "executionDate":"2026-08-10",
                "status":"open",
                "cursor":key_cursor
            })
            .to_string(),
        );
        assert!(matches!(error, Err(StoreError::Invalid(_))));

        let mut timestamp_cursor = first_filtered_cursor(&store, &queued, "cursor-timestamp-first");
        timestamp_cursor["updatedAt"] = Value::String("2026-08-09T00:00:00Z".to_owned());
        let error = store.execute_assistant_tool(
            &queued.turn.id,
            "cursor-timestamp-mismatch",
            "list_state",
            &json!({
                "executionDate":"2026-08-10",
                "status":"open",
                "cursor":timestamp_cursor
            })
            .to_string(),
        );
        assert!(matches!(error, Err(StoreError::Invalid(_))));
    }

    #[test]
    fn assistant_filtered_list_state_rejects_stale_task_snapshots() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let tasks = (0..5)
            .map(|index| {
                store
                    .create_task(&format!("任务 {index}"), "", None, Some("2026-08-10"), None)
                    .unwrap()
            })
            .collect::<Vec<_>>();
        let queued = running_assistant_turn(&store, "游标快照校验");

        let create_cursor = first_filtered_cursor(&store, &queued, "stale-create-first");
        store
            .create_task("新增任务", "", None, Some("2026-08-10"), None)
            .unwrap();
        let error = store.execute_assistant_tool(
            &queued.turn.id,
            "stale-after-create",
            "list_state",
            &json!({
                "executionDate":"2026-08-10",
                "status":"open",
                "cursor":create_cursor
            })
            .to_string(),
        );
        assert!(matches!(
            error,
            Err(StoreError::Conflict("list_state_cursor_stale"))
        ));

        let title_cursor = first_filtered_cursor(&store, &queued, "stale-title-first");
        store
            .update_task(
                &tasks[0].id,
                &UpdateTaskInput {
                    title: Some("修改标题".to_owned()),
                    ..Default::default()
                },
            )
            .unwrap();
        let error = store.execute_assistant_tool(
            &queued.turn.id,
            "stale-after-title",
            "list_state",
            &json!({
                "executionDate":"2026-08-10",
                "status":"open",
                "cursor":title_cursor
            })
            .to_string(),
        );
        assert!(matches!(
            error,
            Err(StoreError::Conflict("list_state_cursor_stale"))
        ));

        let date_cursor = first_filtered_cursor(&store, &queued, "stale-date-first");
        store
            .update_task(
                &tasks[1].id,
                &UpdateTaskInput {
                    execution_date: Some(Some("2026-08-11".to_owned())),
                    ..Default::default()
                },
            )
            .unwrap();
        let error = store.execute_assistant_tool(
            &queued.turn.id,
            "stale-after-date",
            "list_state",
            &json!({
                "executionDate":"2026-08-10",
                "status":"open",
                "cursor":date_cursor
            })
            .to_string(),
        );
        assert!(matches!(
            error,
            Err(StoreError::Conflict("list_state_cursor_stale"))
        ));

        let status_cursor = first_filtered_cursor(&store, &queued, "stale-status-first");
        store
            .set_task_status(&tasks[2].id, TaskStatus::Completed)
            .unwrap();
        let error = store.execute_assistant_tool(
            &queued.turn.id,
            "stale-after-status",
            "list_state",
            &json!({
                "executionDate":"2026-08-10",
                "status":"open",
                "cursor":status_cursor
            })
            .to_string(),
        );
        assert!(matches!(
            error,
            Err(StoreError::Conflict("list_state_cursor_stale"))
        ));
    }

    #[test]
    fn assistant_ui_history_never_loads_provider_steps() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("cursor test").unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "hello",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        let steps = store
            .append_assistant_steps(
                &queued.turn.id,
                1,
                &[
                    ("thought", None, Some(r#"{"type":"thought"}"#), Some(0)),
                    (
                        "model_output",
                        None,
                        Some(r#"{"type":"model_output"}"#),
                        Some(1),
                    ),
                ],
            )
            .unwrap();
        let reply = store
            .append_assistant_message(
                &session.id,
                &queued.turn.id,
                "todoagent",
                "text",
                "world",
                None,
                None,
            )
            .unwrap();

        assert_eq!(queued.message.sequence, 1);
        assert_eq!(reply.sequence, 2);
        assert_eq!(steps[0].sequence, 1);
        assert_eq!(steps[1].sequence, 2);

        // UI pagination returns only visible messages (and tool cards), never
        // hidden provider steps from an independent sequence space.
        let history = store.assistant_history(&session.id, 1, 100).unwrap();
        assert_eq!(history.messages, vec![reply]);
        assert!(history.tools.is_empty());
        assert_eq!(history.session.last_sequence, 2);

        let context = store.assistant_context_history(&session.id).unwrap();
        assert_eq!(context.steps, steps);
        assert_eq!(context.messages, vec![queued.message]);
    }

    #[test]
    fn assistant_history_projects_stable_ordered_parts_without_private_thought_data() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("ordered parts").unwrap();
        let welcome_id = Uuid::new_v4().to_string();
        let timestamp = now();
        store
            .connection
            .execute(
                "INSERT INTO chat_message(id,session_id,sequence,role,kind,body,created_at,updated_at)
                 VALUES(?1,?2,1,'todoagent','text','欢迎',?3,?3)",
                params![welcome_id, session.id, timestamp],
            )
            .unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "检查任务",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        store
            .append_assistant_steps(
                &queued.turn.id,
                1,
                &[
                    (
                        "thought",
                        None,
                        Some(
                            r#"{"type":"thought","signature":"PRIVATE-SIGNATURE","summary":[{"type":"text","text":"先检查任务"}]}"#,
                        ),
                        Some(0),
                    ),
                    (
                        "function_call",
                        Some("list_state"),
                        Some(
                            r#"{"type":"function_call","id":"call-1","name":"list_state","arguments":{"status":"open"}}"#,
                        ),
                        Some(1),
                    ),
                    (
                        "function_result",
                        Some("list_state"),
                        Some(
                            r#"{"type":"function_result","call_id":"call-1","name":"list_state","result":{"count":2},"is_error":false}"#,
                        ),
                        Some(2),
                    ),
                    (
                        "model_output",
                        None,
                        Some(
                            r#"{"type":"model_output","content":[{"type":"text","text":"共有两个任务"}]}"#,
                        ),
                        Some(3),
                    ),
                ],
            )
            .unwrap();
        store
            .complete_assistant_turn_with_message(
                &session.id,
                &queued.turn.id,
                "共有两个任务",
                None,
                None,
            )
            .unwrap();

        let welcome_page = store.assistant_history(&session.id, 0, 1).unwrap();
        assert_eq!(welcome_page.timeline.len(), 1);
        assert_eq!(welcome_page.timeline[0].body, "欢迎");
        assert!(welcome_page.timeline[0].turn_id.starts_with("standalone-"));

        let user_page = store.assistant_history(&session.id, 1, 1).unwrap();
        assert_eq!(
            user_page
                .timeline
                .iter()
                .map(|item| item.kind.as_str())
                .collect::<Vec<_>>(),
            ["user", "reasoning", "tool", "assistant_text"]
        );
        let tool = user_page
            .timeline
            .iter()
            .find(|item| item.kind == "tool")
            .unwrap();
        assert_eq!(tool.input_json.as_deref(), Some(r#"{"status":"open"}"#));
        assert_eq!(tool.output_text.as_deref(), Some(r#"{"count":2}"#));
        assert_eq!(tool.tool_state.as_deref(), Some("completed"));
        let stable_parts = user_page
            .timeline
            .iter()
            .filter(|item| item.source_event_sequence.is_some())
            .map(|item| (item.id.clone(), item.sequence))
            .collect::<Vec<_>>();

        let final_page = store.assistant_history(&session.id, 2, 100).unwrap();
        let final_parts = final_page
            .timeline
            .iter()
            .filter(|item| item.source_event_sequence.is_some())
            .map(|item| (item.id.clone(), item.sequence))
            .collect::<Vec<_>>();
        assert_eq!(stable_parts, final_parts);
        assert_eq!(
            final_page
                .timeline
                .iter()
                .filter(|item| item.kind == "assistant_text")
                .count(),
            1
        );
        let encoded = serde_json::to_string(&final_page.timeline).unwrap();
        assert!(!encoded.contains("PRIVATE-SIGNATURE"));
        assert!(encoded.contains("先检查任务"));
    }

    #[test]
    fn assistant_history_500_one_mib_rows_stop_before_the_decode_budget() {
        let connection = Connection::open_in_memory().unwrap();
        let mut statement = connection
            .prepare(
                "WITH RECURSIVE message_number(value) AS (
                   VALUES(1)
                   UNION ALL SELECT value+1 FROM message_number WHERE value<500
                 )
                 SELECT printf('message-%d',value),'session',NULL,value,NULL,
                        'todoagent','text',printf('%*s',1048576,'x'),NULL,NULL,
                        '2026-08-11T00:00:00Z','2026-08-11T00:00:00Z'
                 FROM message_number ORDER BY value",
            )
            .unwrap();
        let mut rows = statement.query([]).unwrap();
        let messages = collect_bounded_assistant_message_rows(&mut rows).unwrap();
        assert!(!messages.is_empty());
        assert!(messages.len() < 500);
        assert!(messages.last().unwrap().sequence > 0);
        assert!(
            messages.iter().map(serialized_wire_bytes).sum::<usize>()
                <= ASSISTANT_HISTORY_MESSAGE_PAGE_MAX_BYTES
                || messages.len() == 1
        );
    }

    #[test]
    fn assistant_history_message_budget_pages_advance_without_duplicates() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("large messages").unwrap();
        let timestamp = now();
        let body = "答".repeat(SESSION_TIMELINE_TEXT_MAX_BYTES / "答".len());
        let transaction = store.connection.unchecked_transaction().unwrap();
        for sequence in 1..=12_i64 {
            transaction
                .execute(
                    "INSERT INTO chat_message(
                       id,session_id,sequence,role,kind,body,created_at,updated_at
                     ) VALUES(?1,?2,?3,'todoagent','text',?4,?5,?5)",
                    params![
                        format!("large-message-{sequence}"),
                        session.id,
                        sequence,
                        body,
                        timestamp
                    ],
                )
                .unwrap();
        }
        transaction.commit().unwrap();

        let mut cursor = 0_i64;
        let mut seen = HashSet::new();
        let mut pages = 0;
        while cursor < 12 {
            let history = store.assistant_history(&session.id, cursor, 500).unwrap();
            pages += 1;
            assert_eq!(history.session.last_sequence, 12);
            assert!(!history.messages.is_empty());
            assert!(
                history
                    .messages
                    .iter()
                    .map(serialized_wire_bytes)
                    .sum::<usize>()
                    <= ASSISTANT_HISTORY_MESSAGE_PAGE_MAX_BYTES
                    || history.messages.len() == 1
            );
            let next = history
                .messages
                .iter()
                .map(|message| message.sequence)
                .max()
                .unwrap();
            assert!(next > cursor);
            for message in history.messages {
                assert!(seen.insert(message.id));
            }
            cursor = next;
            assert!(pages < 10);
        }
        assert!(pages > 1);
        assert_eq!(seen.len(), 12);
    }

    #[test]
    fn assistant_history_many_steps_is_bounded_and_keeps_final_message_with_partial_notice() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("large steps").unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "分析大量步骤",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        let summaries = (0..40)
            .map(|index| {
                json!({
                    "type":"thought",
                    "summary":[{
                        "type":"text",
                        "text":format!("{index}-{}", "思".repeat(
                            SESSION_TIMELINE_REASONING_MAX_BYTES / "思".len()
                        ))
                    }]
                })
                .to_string()
            })
            .collect::<Vec<_>>();
        let steps = summaries
            .iter()
            .enumerate()
            .map(|(index, payload)| ("thought", None, Some(payload.as_str()), Some(index as i64)))
            .collect::<Vec<_>>();
        store
            .append_assistant_steps(&queued.turn.id, 1, &steps)
            .unwrap();
        store
            .complete_assistant_turn_with_message(
                &session.id,
                &queued.turn.id,
                "最终正文必须保留",
                None,
                None,
            )
            .unwrap();

        let first = store.assistant_history(&session.id, 0, 500).unwrap();
        assert!(first.messages.iter().any(|message| {
            message.turn_id.as_deref() == Some(queued.turn.id.as_str())
                && message.role == "todoagent"
                && message.body == "最终正文必须保留"
        }));
        let final_timeline_index = first
            .timeline
            .iter()
            .position(|item| {
                item.turn_id == queued.turn.id
                    && item.kind == "assistant_text"
                    && item.body == "最终正文必须保留"
            })
            .expect("the authoritative timeline must retain the final answer");
        let notice = first.timeline.last().unwrap();
        assert!(final_timeline_index < first.timeline.len() - 1);
        assert_eq!(notice.kind, "status");
        assert_eq!(notice.fidelity, "partial");
        assert!(notice.body.contains("最终回复仍保留"));
        let metadata: Value =
            serde_json::from_str(notice.metadata_json.as_deref().unwrap()).unwrap();
        assert_eq!(metadata["reason"], "history_detail_budget");
        assert_eq!(metadata["truncated"], true);
        assert!(
            serde_json::to_vec(&first).unwrap().len()
                <= ASSISTANT_HISTORY_MESSAGE_PAGE_MAX_BYTES
                    + ASSISTANT_HISTORY_DETAIL_PAGE_MAX_BYTES
                    + 128 * 1024
        );
        let repeated = store.assistant_history(&session.id, 0, 500).unwrap();
        assert_eq!(repeated.timeline.last().unwrap().id, notice.id);
        assert_eq!(
            store
                .assistant_final_message_for_turn(&queued.turn.id)
                .unwrap()
                .unwrap()
                .body,
            "最终正文必须保留"
        );
    }

    #[test]
    fn assistant_turn_writes_require_running_state_and_error_receipts_round_trip() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("state test").unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "hello",
                None,
                Some("model-x"),
            )
            .unwrap();

        assert!(matches!(
            store.append_assistant_step(
                &queued.turn.id,
                "model_output",
                "completed",
                None,
                None,
                1,
                Some(0)
            ),
            Err(StoreError::Conflict("assistant_turn_not_running"))
        ));
        assert!(matches!(
            store.append_assistant_message(
                &session.id,
                &queued.turn.id,
                "todoagent",
                "text",
                "too early",
                None,
                None
            ),
            Err(StoreError::Conflict("assistant_turn_not_running"))
        ));
        assert!(matches!(
            store.execute_assistant_tool(&queued.turn.id, "early-call", "list_lists", "{}"),
            Err(StoreError::Conflict("assistant_turn_not_running"))
        ));

        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        let receipt = store
            .save_assistant_tool_execution(
                &session.id,
                &queued.turn.id,
                None,
                "bad-call",
                "unknown_tool",
                "{}",
                Some(r#"{"error":"unknown tool"}"#),
                true,
                "completed",
                Some("unknown_tool"),
                Some("unknown tool"),
            )
            .unwrap();
        assert!(receipt.is_error);
        assert_eq!(
            receipt.response_json.as_deref(),
            Some(r#"{"error":"unknown tool"}"#)
        );

        store
            .finish_assistant_turn(
                &queued.turn.id,
                AssistantTurnStatus::Completed,
                Some("done"),
                None,
                None,
                None,
            )
            .unwrap();
        assert!(matches!(
            store.append_assistant_steps(
                &queued.turn.id,
                2,
                &[("model_output", None, None, Some(0))]
            ),
            Err(StoreError::Conflict("assistant_turn_not_running"))
        ));
        assert!(matches!(
            store.save_assistant_tool_execution(
                &session.id,
                &queued.turn.id,
                None,
                "late-call",
                "list_lists",
                "{}",
                Some("{}"),
                false,
                "completed",
                None,
                None,
            ),
            Err(StoreError::Conflict("assistant_turn_not_running"))
        ));
    }

    #[test]
    fn assistant_compaction_step_watermark_is_bounded_and_monotonic() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("compaction test").unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "hello",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        store
            .append_assistant_steps(
                &queued.turn.id,
                1,
                &[
                    ("thought", None, None, Some(0)),
                    ("model_output", None, None, Some(1)),
                ],
            )
            .unwrap();
        store
            .finish_assistant_turn(
                &queued.turn.id,
                AssistantTurnStatus::Completed,
                Some("done"),
                None,
                None,
                None,
            )
            .unwrap();

        assert!(matches!(
            store.save_assistant_compaction(&session.id, 1, "split", None),
            Err(StoreError::Invalid(message))
                if message == "assistant compaction must end at a completed turn boundary"
        ));

        let saved = store
            .save_assistant_compaction(&session.id, 2, "summary", None)
            .unwrap();
        assert_eq!(saved.through_sequence, 2);
        assert!(matches!(
            store.save_assistant_compaction(&session.id, 3, "future", None),
            Err(StoreError::Invalid(message))
                if message == "assistant compaction exceeds step high-water mark"
        ));
        assert!(matches!(
            store.save_assistant_compaction(&session.id, 1, "regression", None),
            Err(StoreError::Conflict("assistant_compaction_regression"))
        ));

        let updated = store
            .save_assistant_compaction(&session.id, 2, "updated summary", None)
            .unwrap();
        assert_eq!(updated.summary, "updated summary");
        let compacted_history = store.assistant_context_history(&session.id).unwrap();
        assert!(compacted_history.steps.is_empty());
        assert_eq!(
            compacted_history
                .compaction
                .as_ref()
                .map(|value| value.through_sequence),
            Some(2)
        );
    }

    #[test]
    fn assistant_context_loads_latest_complete_turns_without_row_clipping() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("long context").unwrap();
        let first = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "第一轮",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&first.turn.id).unwrap();
        let payloads = (0..2_005)
            .map(|index| json!({"type":"model_output","content":[{"type":"text","text":format!("片段 {index}")}]}).to_string())
            .collect::<Vec<_>>();
        let steps = payloads
            .iter()
            .enumerate()
            .map(|(index, payload)| {
                (
                    "model_output",
                    None,
                    Some(payload.as_str()),
                    Some(index as i64),
                )
            })
            .collect::<Vec<_>>();
        store
            .append_assistant_steps(&first.turn.id, 1, &steps)
            .unwrap();
        store
            .finish_assistant_turn(
                &first.turn.id,
                AssistantTurnStatus::Completed,
                Some("第一轮完成"),
                None,
                None,
                None,
            )
            .unwrap();
        let current = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "当前轮",
                None,
                Some("model-x"),
            )
            .unwrap();

        let context = store.assistant_context_history(&session.id).unwrap();
        assert_eq!(context.steps.len(), 2_005);
        assert_eq!(context.steps.first().unwrap().sequence, 1);
        assert_eq!(context.steps.last().unwrap().sequence, 2_005);
        assert_eq!(
            context
                .messages
                .iter()
                .map(|message| message.body.as_str())
                .collect::<Vec<_>>(),
            vec!["第一轮", "当前轮"]
        );
        assert_eq!(context.active_turn.unwrap().id, current.turn.id);

        // Rendering the same session does not touch the 2,005 hidden rows.
        let ui = store.assistant_history(&session.id, 0, 100).unwrap();
        assert_eq!(ui.messages.len(), 2);
        assert!(ui.tools.is_empty());
    }

    #[test]
    fn assistant_tool_results_are_bounded_without_rolling_back_mutations() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("bounded tools").unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "创建很多长备注任务",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        let note = "长".repeat(4_000);
        let create_arguments = json!({
            "tasks": (0..10).map(|index| json!({
                "title": format!("长备注任务 {index}"),
                "note": note.clone(),
            })).collect::<Vec<_>>()
        });
        let created = store
            .execute_assistant_tool(
                &queued.turn.id,
                "long-create",
                "create_tasks",
                &create_arguments.to_string(),
            )
            .unwrap();
        assert!(created.result_json.len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES);
        assert_eq!(store.tasks().unwrap().len(), 10);
        assert_eq!(
            serde_json::from_str::<Value>(&created.result_json).unwrap()["truncated"],
            true
        );

        let found = store
            .execute_assistant_tool(
                &queued.turn.id,
                "long-find",
                "find_related",
                r#"{"query":"长备注任务"}"#,
            )
            .unwrap();
        assert!(found.result_json.len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES);
        assert_eq!(
            serde_json::from_str::<Value>(&found.result_json).unwrap()["truncated"],
            true
        );

        let state = store
            .execute_assistant_tool(&queued.turn.id, "long-state", "list_state", "{}")
            .unwrap();
        assert!(state.result_json.len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES);
        assert_eq!(
            serde_json::from_str::<Value>(&state.result_json).unwrap()["truncated"],
            true
        );
        assert!(
            serde_json::from_str::<Value>(&state.result_json).unwrap()["tasks"]["open"]
                .as_array()
                .is_some_and(|tasks| !tasks.is_empty())
        );

        let task_id = serde_json::from_str::<Value>(&created.task_refs_json).unwrap()[0]
            .as_str()
            .unwrap()
            .to_owned();
        let updated = store
            .execute_assistant_tool(
                &queued.turn.id,
                "long-update",
                "update_task",
                &json!({"taskId":task_id,"note":"新".repeat(4_000)}).to_string(),
            )
            .unwrap();
        assert!(updated.result_json.len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES);
        assert_eq!(
            serde_json::from_str::<Value>(&updated.result_json).unwrap()["truncated"],
            true
        );

        let oversized_error = json!({"error":"错".repeat(4_000)}).to_string();
        let saved_error = store
            .save_assistant_tool_execution(
                &session.id,
                &queued.turn.id,
                None,
                "long-error",
                "find_related",
                "{}",
                Some(&oversized_error),
                true,
                "completed",
                Some("tool_failed"),
                Some("too large"),
            )
            .unwrap();
        assert!(
            saved_error
                .response_json
                .as_ref()
                .is_some_and(|response| response.len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES)
        );

        for index in 0..60 {
            let timestamp = now();
            store
                .connection
                .execute(
                    "INSERT INTO list(id,name,color,repository_path,created_at,updated_at)
                 VALUES(?1,?2,'blue',?3,?4,?4)",
                    params![
                        Uuid::new_v4().to_string(),
                        format!("清单 {index} {}", "名".repeat(500)),
                        format!("/Users/example/TopSecret/{index}/{}", "目录/".repeat(500)),
                        timestamp,
                    ],
                )
                .unwrap();
        }
        let lists = store
            .execute_assistant_tool(&queued.turn.id, "long-lists", "list_lists", "{}")
            .unwrap();
        assert!(lists.result_json.len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES);
        assert_eq!(
            serde_json::from_str::<Value>(&lists.result_json).unwrap()["truncated"],
            true
        );
        let lists_value = serde_json::from_str::<Value>(&lists.result_json).unwrap();
        assert!(
            lists_value["lists"]
                .as_array()
                .is_some_and(|lists| !lists.is_empty())
        );
        assert!(lists_value["next"].is_string());
        assert!(!lists.result_json.contains("repositoryPath"));
        assert!(!lists.result_json.contains("TopSecret"));

        let state_with_lists = store
            .execute_assistant_tool(&queued.turn.id, "long-state-with-lists", "list_state", "{}")
            .unwrap();
        let state_value = serde_json::from_str::<Value>(&state_with_lists.result_json).unwrap();
        assert!(state_with_lists.result_json.len() <= ASSISTANT_TOOL_RESULT_MAX_BYTES);
        assert!(
            state_value["lists"]
                .as_array()
                .is_some_and(|lists| !lists.is_empty())
        );
        assert!(
            state_value["tasks"]["open"]
                .as_array()
                .is_some_and(|tasks| !tasks.is_empty())
        );
        assert!(state_value["next"].is_string());
        assert!(!state_with_lists.result_json.contains("repositoryPath"));
        assert!(!state_with_lists.result_json.contains("TopSecret"));

        let history = store.assistant_history(&session.id, 0, 100).unwrap();
        assert_eq!(history.tools.len(), 7);
        assert!(
            history
                .tools
                .iter()
                .all(|tool| tool.turn_id.as_deref() == Some(queued.turn.id.as_str()))
        );
        assert!(
            history
                .tools
                .iter()
                .any(|tool| tool.call_id == "long-error" && tool.is_error)
        );
    }

    #[test]
    fn assistant_client_message_id_rejects_different_payload() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("idempotency").unwrap();
        let client_id = Uuid::new_v4().to_string();
        let first = store
            .begin_assistant_turn(&session.id, &client_id, "完全相同", None, Some("model-a"))
            .unwrap();
        let duplicate = store
            .begin_assistant_turn(&session.id, &client_id, "完全相同", None, Some("model-a"))
            .unwrap();
        assert_eq!(duplicate.turn.id, first.turn.id);
        assert!(!duplicate.is_new);
        assert!(matches!(
            store.begin_assistant_turn(&session.id, &client_id, "不同正文", None, Some("model-a")),
            Err(StoreError::Conflict(
                "assistant_client_message_payload_mismatch"
            ))
        ));
        assert!(matches!(
            store.begin_assistant_turn(&session.id, &client_id, "完全相同", None, Some("model-b")),
            Err(StoreError::Conflict(
                "assistant_client_message_payload_mismatch"
            ))
        ));
    }

    #[test]
    fn assistant_attachment_payload_is_persisted_and_part_of_idempotency() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("attachments").unwrap();
        let client_id = Uuid::new_v4().to_string();
        let first_payload = r##"{"attachments":[{"name":"notes.md","mediaType":"text/markdown","content":"# Notes","byteCount":7}]}"##;
        let second_payload = r##"{"attachments":[{"name":"notes.md","mediaType":"text/markdown","content":"# Changed","byteCount":9}]}"##;

        let first = store
            .begin_assistant_turn_with_payload(
                &session.id,
                &client_id,
                "请处理这些附件",
                Some(first_payload),
                None,
                Some("model-a"),
            )
            .unwrap();
        assert_eq!(first.message.body, "请处理这些附件");
        assert_eq!(first.message.payload_json.as_deref(), Some(first_payload));

        let duplicate = store
            .begin_assistant_turn_with_payload(
                &session.id,
                &client_id,
                "请处理这些附件",
                Some(first_payload),
                None,
                Some("model-a"),
            )
            .unwrap();
        assert_eq!(duplicate.turn.id, first.turn.id);
        assert!(!duplicate.is_new);

        assert!(matches!(
            store.begin_assistant_turn_with_payload(
                &session.id,
                &client_id,
                "请处理这些附件",
                Some(second_payload),
                None,
                Some("model-a"),
            ),
            Err(StoreError::Conflict(
                "assistant_client_message_payload_mismatch"
            ))
        ));
    }

    #[test]
    fn completing_message_and_turn_is_one_transaction() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("atomic final").unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "hello",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        let (message, turn) = store
            .complete_assistant_turn_with_message(
                &session.id,
                &queued.turn.id,
                "最终回复",
                Some(r#"["task-1"]"#),
                Some(r#"{"outputTokens":12}"#),
            )
            .unwrap();
        assert_eq!(message.body, "最终回复");
        assert_eq!(message.task_refs_json.as_deref(), Some(r#"["task-1"]"#));
        assert_eq!(turn.status, AssistantTurnStatus::Completed);
        assert_eq!(turn.final_output.as_deref(), Some("最终回复"));
        assert_eq!(turn.usage_json.as_deref(), Some(r#"{"outputTokens":12}"#));
        assert!(matches!(
            store.finish_assistant_turn(
                &queued.turn.id,
                AssistantTurnStatus::Cancelled,
                None,
                Some("cancelled"),
                Some("late cancellation"),
                None,
            ),
            Err(StoreError::Conflict("assistant_turn_already_finished"))
        ));
    }

    #[test]
    fn assistant_terminal_snapshot_failure_rolls_back_message_and_turn() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store
            .create_assistant_session("terminal read failure")
            .unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "hello",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        store
            .connection
            .execute_batch(
                "CREATE TEMP TRIGGER fail_assistant_terminal_snapshot
                 AFTER UPDATE OF status ON assistant_turn
                 WHEN NEW.status='completed'
                 BEGIN
                   DELETE FROM chat_session WHERE id=NEW.session_id;
                 END;",
            )
            .unwrap();

        let result = store.complete_assistant_turn_with_message(
            &session.id,
            &queued.turn.id,
            "不得提交",
            None,
            None,
        );
        assert!(matches!(result, Err(StoreError::NotFound)));
        assert_eq!(
            store
                .assistant_turn(&queued.turn.id)
                .unwrap()
                .unwrap()
                .status,
            AssistantTurnStatus::Running
        );
        let committed_final_messages: i64 = store
            .connection
            .query_row(
                "SELECT count(*) FROM chat_message
                 WHERE turn_id=?1 AND role='todoagent' AND kind='text'",
                [&queued.turn.id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(committed_final_messages, 0);
    }

    #[test]
    fn cancelling_multi_tool_turn_pairs_executed_and_unexecuted_calls() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let session = store.create_assistant_session("cancel repair").unwrap();
        let queued = store
            .begin_assistant_turn(
                &session.id,
                &Uuid::new_v4().to_string(),
                "创建两个任务",
                None,
                Some("model-x"),
            )
            .unwrap();
        store.mark_assistant_turn_running(&queued.turn.id).unwrap();
        store
            .append_assistant_steps(
                &queued.turn.id,
                1,
                &[
                    (
                        "function_call",
                        Some("create_tasks"),
                        Some(r#"{"type":"function_call","id":"done-call","name":"create_tasks","arguments":{"tasks":[{"title":"已执行"}]}}"#),
                        Some(0),
                    ),
                    (
                        "function_call",
                        Some("create_tasks"),
                        Some(r#"{"type":"function_call","id":"not-run-call","name":"create_tasks","arguments":{"tasks":[{"title":"不得执行"}]}}"#),
                        Some(1),
                    ),
                ],
            )
            .unwrap();
        store
            .execute_assistant_tool(
                &queued.turn.id,
                "done-call",
                "create_tasks",
                r#"{"tasks":[{"title":"已执行"}]}"#,
            )
            .unwrap();
        let (system_message, cancelled) = store
            .finish_assistant_turn_with_message(
                &session.id,
                &queued.turn.id,
                AssistantTurnStatus::Cancelled,
                Some(("status", "已取消本轮")),
                None,
                Some("cancelled"),
                Some("用户取消"),
                None,
            )
            .unwrap();

        assert_eq!(cancelled.status, AssistantTurnStatus::Cancelled);
        assert_eq!(system_message.unwrap().body, "已取消本轮");
        assert_eq!(store.tasks().unwrap().len(), 1);
        let context = store.assistant_context_history(&session.id).unwrap();
        let results = context
            .steps
            .iter()
            .filter(|step| step.kind == "function_result")
            .filter_map(|step| step.payload_json.as_deref())
            .map(|payload| serde_json::from_str::<Value>(payload).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.len(), 2);
        assert_eq!(
            results
                .iter()
                .find(|value| value["call_id"] == "done-call")
                .unwrap()["is_error"],
            false
        );
        let skipped = results
            .iter()
            .find(|value| value["call_id"] == "not-run-call")
            .unwrap();
        assert_eq!(skipped["is_error"], true);
        assert_eq!(skipped["result"]["executed"], false);
        assert_eq!(skipped["result"]["error"]["code"], "turn_cancelled");

        let (replayed_message, replayed_turn) = store
            .finish_assistant_turn_with_message(
                &session.id,
                &queued.turn.id,
                AssistantTurnStatus::Cancelled,
                Some(("status", "不应重复")),
                None,
                Some("cancelled"),
                Some("用户取消"),
                None,
            )
            .unwrap();
        assert!(replayed_message.is_none());
        assert_eq!(replayed_turn.id, cancelled.id);
        assert_eq!(replayed_turn.status, AssistantTurnStatus::Cancelled);
    }

    #[test]
    fn restart_repairs_receipt_without_reexecuting_tool() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("todoagent.sqlite3");
        let (session_id, turn_id);
        {
            let store = Store::open(&path).unwrap();
            let session = store.create_assistant_session("crash repair").unwrap();
            session_id = session.id;
            let queued = store
                .begin_assistant_turn(
                    &session_id,
                    &Uuid::new_v4().to_string(),
                    "创建一次",
                    None,
                    Some("model-x"),
                )
                .unwrap();
            turn_id = queued.turn.id;
            store.mark_assistant_turn_running(&turn_id).unwrap();
            store
                .append_assistant_steps(
                    &turn_id,
                    1,
                    &[
                        (
                            "function_call",
                            Some("create_tasks"),
                            Some(r#"{"type":"function_call","id":"crash-call","name":"create_tasks","arguments":{"tasks":[{"title":"只创建一次"}]}}"#),
                            Some(0),
                        ),
                        (
                            "function_call",
                            Some("create_tasks"),
                            Some(r#"{"type":"function_call","id":"never-ran","name":"create_tasks","arguments":{"tasks":[{"title":"不能补执行"}]}}"#),
                            Some(1),
                        ),
                    ],
                )
                .unwrap();
            store
                .execute_assistant_tool(
                    &turn_id,
                    "crash-call",
                    "create_tasks",
                    r#"{"tasks":[{"title":"只创建一次"}]}"#,
                )
                .unwrap();
            assert_eq!(store.tasks().unwrap().len(), 1);
            // Simulate a crash before AgentRunner persists function_result.
        }

        let recovered = Store::open(&path).unwrap();
        assert_eq!(recovered.tasks().unwrap().len(), 1);
        let context = recovered.assistant_context_history(&session_id).unwrap();
        let payloads = context
            .steps
            .iter()
            .filter_map(|step| step.payload_json.as_deref())
            .map(|payload| serde_json::from_str::<Value>(payload).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            payloads
                .iter()
                .filter(|payload| payload["type"] == "function_call")
                .count(),
            2
        );
        assert_eq!(
            payloads
                .iter()
                .filter(|payload| {
                    payload["type"] == "function_result" && payload["call_id"] == "crash-call"
                })
                .count(),
            1
        );
        let skipped = payloads
            .iter()
            .find(|payload| {
                payload["type"] == "function_result" && payload["call_id"] == "never-ran"
            })
            .unwrap();
        assert_eq!(skipped["is_error"], true);
        assert_eq!(skipped["result"]["executed"], false);
        assert_eq!(skipped["result"]["error"]["code"], "engine_interrupted");
        assert_eq!(
            recovered.assistant_turn(&turn_id).unwrap().unwrap().status,
            AssistantTurnStatus::Interrupted
        );
    }

    #[test]
    fn startup_repairs_legacy_terminal_turns_with_dangling_calls() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("todoagent.sqlite3");
        let mut sessions = Vec::new();
        {
            let store = Store::open(&path).unwrap();
            for (status, expected_code) in [
                ("failed", "turn_failed"),
                ("cancelled", "turn_cancelled"),
                ("interrupted", "engine_interrupted"),
            ] {
                let session = store.create_assistant_session(status).unwrap();
                let queued = store
                    .begin_assistant_turn(
                        &session.id,
                        &Uuid::new_v4().to_string(),
                        "旧历史",
                        None,
                        Some("model-x"),
                    )
                    .unwrap();
                store.mark_assistant_turn_running(&queued.turn.id).unwrap();
                let call_payload = format!(
                    r#"{{"type":"function_call","id":"{status}-call","name":"list_state","arguments":{{}}}}"#
                );
                store
                    .append_assistant_steps(
                        &queued.turn.id,
                        1,
                        &[(
                            "function_call",
                            Some("list_state"),
                            Some(call_payload.as_str()),
                            Some(0),
                        )],
                    )
                    .unwrap();
                // Simulate a database written by an older build that terminalized
                // the turn without first pairing the provider call.
                store
                    .connection
                    .execute(
                        "UPDATE assistant_turn SET status=?1 WHERE id=?2",
                        params![status, queued.turn.id],
                    )
                    .unwrap();
                sessions.push((session.id, format!("{status}-call"), expected_code));
            }
        }

        let recovered = Store::open(&path).unwrap();
        let repaired_revision = recovered.revision().unwrap();
        for (session_id, call_id, expected_code) in sessions {
            let context = recovered.assistant_context_history(&session_id).unwrap();
            let result = context
                .steps
                .iter()
                .filter_map(|step| step.payload_json.as_deref())
                .map(|payload| serde_json::from_str::<Value>(payload).unwrap())
                .find(|payload| {
                    payload["type"] == "function_result" && payload["call_id"] == call_id
                })
                .unwrap();
            assert_eq!(result["is_error"], true);
            assert_eq!(result["result"]["error"]["code"], expected_code);
        }
        drop(recovered);
        let clean_reopen = Store::open(&path).unwrap();
        assert_eq!(clean_reopen.revision().unwrap(), repaired_revision);
    }

    #[test]
    fn assistant_open_reconciles_interrupted_turns() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("todoagent.sqlite3");
        let turn_id;
        {
            let store = Store::open(&path).unwrap();
            let session = store.create_assistant_session("test").unwrap();
            let client_id = Uuid::new_v4().to_string();
            turn_id = store
                .begin_assistant_turn(&session.id, &client_id, "hello", None, Some("model-x"))
                .unwrap()
                .turn
                .id;
        }
        let recovered = Store::open(&path).unwrap();
        assert_eq!(
            recovered.assistant_turn(&turn_id).unwrap().unwrap().status,
            AssistantTurnStatus::Interrupted
        );
    }
}
