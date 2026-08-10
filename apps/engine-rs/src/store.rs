use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::fs;
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path};
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
    MessageRole, QueuedAssistantTurn, QueuedTurn, Runtime, RuntimeKind, SessionBundle,
    SessionMessage, SessionState, SessionTurn, Task, TaskAttachment, TaskSession, TaskState,
    TaskStatus, TurnStatus, UpdateTaskInput,
};

pub const SCHEMA_VERSION: i64 = 4;
const SCHEMA_CHECKSUM: &str = "todoagent-native-v4-unified-task-time-and-attachments";
const ASSISTANT_TOOL_RESULT_MAX_BYTES: usize = 8 * 1024;
const ASSISTANT_FILTERED_TASK_PAGE_SIZE: usize = 50;

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
    /// successfully opened at schema v4. Operations are limited to direct
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
        transaction.commit()?;
        self.assistant_turn(turn_id)?.ok_or(StoreError::NotFound)
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
        transaction.execute(
            "UPDATE assistant_turn SET status=?1,final_output=coalesce(?2,final_output),
             error_code=coalesce(?3,error_code),error_message=coalesce(?4,error_message),
             usage_json=coalesce(?5,usage_json),ended_at=coalesce(ended_at,?6),updated_at=?6 WHERE id=?7",
            params![status.as_str(), final_output, error_code, error_message, usage_json, timestamp, turn_id],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.assistant_turn(turn_id)?.ok_or(StoreError::NotFound)
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
                transaction.commit()?;
                return Ok((
                    None,
                    self.assistant_turn(turn_id)?.ok_or(StoreError::NotFound)?,
                ));
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
            transaction.execute(
                "INSERT INTO chat_message(id,session_id,turn_id,sequence,role,kind,body,created_at,updated_at)
                 VALUES(?1,?2,?3,?4,'system',?5,?6,?7,?7)",
                params![id, session_id, turn_id, sequence, kind, body, timestamp],
            )?;
            Some(id)
        } else {
            None
        };
        transaction.execute(
            "UPDATE assistant_turn SET status=?1,final_output=?2,error_code=?3,error_message=?4,
             usage_json=?5,ended_at=?6,updated_at=?6 WHERE id=?7",
            params![
                status.as_str(),
                final_output,
                error_code,
                error_message,
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
        transaction.commit()?;
        let message = message_id
            .as_deref()
            .map(|id| self.assistant_message(id))
            .transpose()?
            .flatten();
        Ok((
            message,
            self.assistant_turn(turn_id)?.ok_or(StoreError::NotFound)?,
        ))
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
        let sequence = next_assistant_message_sequence(&transaction, session_id)?;
        transaction.execute(
            "INSERT INTO chat_message(id,session_id,turn_id,sequence,role,kind,body,task_refs_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,'todoagent','text',?5,?6,?7,?7)",
            params![id, session_id, turn_id, sequence, text, task_refs_json, timestamp],
        )?;
        transaction.execute(
            "UPDATE assistant_turn SET status='completed',final_output=?1,error_code=NULL,error_message=NULL,
             usage_json=?2,ended_at=?3,updated_at=?3 WHERE id=?4",
            params![text, usage_json, timestamp, turn_id],
        )?;
        transaction.execute(
            "UPDATE chat_session SET updated_at=?1 WHERE id=?2",
            params![timestamp, session_id],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok((
            self.assistant_message(&id)?.ok_or(StoreError::NotFound)?,
            self.assistant_turn(turn_id)?.ok_or(StoreError::NotFound)?,
        ))
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
        transaction.execute(
            "INSERT INTO chat_message(id,session_id,turn_id,sequence,role,kind,body,payload_json,task_refs_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10)",
            params![id, session_id, turn_id, sequence, role, kind, body, payload_json, task_refs_json, timestamp],
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
        transaction.execute(
            "INSERT INTO assistant_step(id,session_id,turn_id,sequence,interaction_ordinal,provider_step_index,kind,status,title,payload_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?11)",
            params![id, session_id, turn_id, sequence, interaction_ordinal, provider_step_index, kind, status, title, payload_json, timestamp],
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
                transaction.execute(
                    "INSERT INTO assistant_step(id,session_id,turn_id,sequence,interaction_ordinal,provider_step_index,kind,status,title,payload_json,created_at,updated_at)
                     VALUES(?1,?2,?3,?4,?5,?6,?7,'completed',?8,?9,?10,?10)",
                    params![id, session_id, turn_id, sequence, interaction_ordinal, provider_step_index, kind, title, payload_json, timestamp],
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
        let task_refs_json = task_refs.to_string();
        let timestamp = now();
        transaction.execute(
            "INSERT INTO assistant_tool_execution(id,session_id,turn_id,call_id,tool_name,request_json,response_json,task_refs_json,is_error,status,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,0,'completed',?9,?9)",
            params![Uuid::new_v4().to_string(), session_id, turn_id, call_id, name, arguments_json, result_json, task_refs_json, timestamp],
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
        let mut messages = self.connection.prepare(
            "SELECT id,session_id,turn_id,sequence,client_message_id,role,kind,body,payload_json,task_refs_json,created_at,updated_at
             FROM chat_message WHERE session_id=?1 AND sequence>?2 ORDER BY sequence LIMIT ?3",
        )?;
        let messages = messages
            .query_map(
                params![session_id, after_sequence, limit],
                row_to_assistant_message,
            )?
            .collect::<Result<Vec<_>, _>>()?;
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
        let tools = if visible_turns.is_empty() {
            Vec::new()
        } else {
            let visible_turns = visible_turns.into_iter().collect::<Vec<_>>();
            let placeholders = std::iter::repeat_n("?", visible_turns.len())
                .collect::<Vec<_>>()
                .join(",");
            let sql = format!(
                "SELECT id,session_id,turn_id,call_id,tool_name,task_refs_json,is_error,status,created_at,updated_at
                 FROM assistant_tool_execution
                 WHERE session_id=? AND turn_id IN ({placeholders})
                 ORDER BY created_at,id"
            );
            let mut tools_statement = self.connection.prepare(&sql)?;
            let arguments =
                std::iter::once(session_id).chain(visible_turns.iter().map(String::as_str));
            tools_statement
                .query_map(params_from_iter(arguments), row_to_assistant_tool_summary)?
                .collect::<Result<Vec<_>, _>>()?
        };
        Ok(AssistantHistory {
            session,
            messages,
            tools,
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
        Ok(self.connection.query_row(
            "SELECT id,session_id,ordinal,user_message_id,model_id,attempt_count,status,final_output,usage_json,error_code,error_message,started_at,ended_at,created_at,updated_at
             FROM assistant_turn WHERE id=?1",
            [id],
            row_to_assistant_turn,
        ).optional()?)
    }

    fn assistant_message(&self, id: &str) -> StoreResult<Option<AssistantMessage>> {
        Ok(self.connection.query_row(
            "SELECT id,session_id,turn_id,sequence,client_message_id,role,kind,body,payload_json,task_refs_json,created_at,updated_at
             FROM chat_message WHERE id=?1",
            [id],
            row_to_assistant_message,
        ).optional()?)
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

    /// Returns an already-created empty session for an exact replay, rejects a
    /// conflicting configuration for the task, or returns `None` when a new
    /// session may be created. Engine performs this read before runtime
    /// validation so a lost successful response remains replayable even if the
    /// runtime later becomes unavailable.
    pub fn prepare_session_create(
        &self,
        task_id: &str,
        runtime_kind: RuntimeKind,
        working_directory: &str,
    ) -> StoreResult<Option<TaskSession>> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        if let Some(existing) = self.session_for_task(&task_id)? {
            let is_empty_replay = existing.runtime_kind == runtime_kind
                && existing.working_directory == working_directory
                && existing.state == SessionState::Idle
                && self.session_turn_count(&existing.id)? == 0;
            if is_empty_replay {
                return Ok(Some(existing));
            }
            return Err(StoreError::Conflict("session_exists"));
        }
        if self.task(&task_id)?.is_none() {
            return Err(StoreError::NotFound);
        }
        Ok(None)
    }

    pub fn create_session(
        &self,
        task_id: &str,
        runtime_kind: RuntimeKind,
        working_directory: &str,
    ) -> StoreResult<TaskSession> {
        let task_id = canonical_uuid(task_id, "taskId")?;
        if let Some(existing) =
            self.prepare_session_create(&task_id, runtime_kind, working_directory)?
        {
            return Ok(existing);
        }
        let timestamp = now();
        let session_id = Uuid::new_v4().to_string();
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "INSERT INTO task_session(id,task_id,runtime_kind,working_directory,provider_engine,state,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,'idle',?6,?6)",
            params![session_id, task_id, runtime_kind.as_str(), working_directory,
                (runtime_kind == RuntimeKind::Kiro).then_some("v2"), timestamp],
        )?;
        bump_revision(&transaction)?;
        transaction.commit()?;
        self.session(&session_id)?.ok_or(StoreError::NotFound)
    }

    pub fn send_message(
        &self,
        session_id: &str,
        client_message_id: &str,
        prompt: &str,
    ) -> StoreResult<QueuedTurn> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let client_message_id = canonical_uuid(client_message_id, "clientMessageId")?;
        if let Some(queued) =
            self.session_turn_for_client_message(&session_id, &client_message_id)?
        {
            return Ok(queued);
        }
        let session = self.session(&session_id)?.ok_or(StoreError::NotFound)?;
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
            [&session_id],
            |row| row.get(0),
        )?;
        let sequence = next_message_sequence(&transaction, &session_id)?;
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
            session: self.session(&session_id)?.ok_or(StoreError::NotFound)?,
            turn: self.turn(&turn_id)?.ok_or(StoreError::NotFound)?,
            prompt: prompt.to_owned(),
            is_new: true,
        })
    }

    /// Looks up an already accepted client message without changing session state.
    /// Engine preflight uses this to preserve idempotent retries even when the
    /// configured runtime becomes unavailable after the original request.
    pub fn session_turn_for_client_message(
        &self,
        session_id: &str,
        client_message_id: &str,
    ) -> StoreResult<Option<QueuedTurn>> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let client_message_id = canonical_uuid(client_message_id, "clientMessageId")?;
        let existing = self.connection.query_row(
            "SELECT turn_id,body FROM session_message WHERE session_id=?1 AND client_message_id=?2",
            params![session_id, client_message_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        ).optional()?;
        existing
            .map(|(turn_id, body)| {
                Ok(QueuedTurn {
                    session: self.session(&session_id)?.ok_or(StoreError::NotFound)?,
                    turn: self.turn(&turn_id)?.ok_or(StoreError::NotFound)?,
                    prompt: body,
                    is_new: false,
                })
            })
            .transpose()
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
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let transaction = self.connection.unchecked_transaction()?;
        let changed = transaction.execute(
            "UPDATE task_session SET provider_session_id=?1,updated_at=?2 WHERE id=?3",
            params![provider_session_id, now(), session_id],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn clear_provider_session(&self, session_id: &str) -> StoreResult<()> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        let transaction = self.connection.unchecked_transaction()?;
        let changed = transaction.execute(
            "UPDATE task_session SET provider_session_id=NULL,updated_at=?1 WHERE id=?2",
            params![now(), session_id],
        )?;
        if changed == 0 {
            return Err(StoreError::NotFound);
        }
        bump_revision(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn recovery_context(&self, session_id: &str, max_bytes: usize) -> StoreResult<String> {
        let task: Task = self.connection.query_row(
            "SELECT t.id,t.list_id,t.title,t.note,t.status,t.execution_date,t.due_date,t.completed_at,t.created_at,t.updated_at
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
        let task_id = canonical_uuid(task_id, "taskId")?;
        Ok(self
            .connection
            .query_row(
                &session_select("WHERE task_id=?1"),
                [&task_id],
                row_to_session,
            )
            .optional()?)
    }

    pub fn session(&self, id: &str) -> StoreResult<Option<TaskSession>> {
        let id = canonical_uuid(id, "sessionId")?;
        Ok(self
            .connection
            .query_row(&session_select("WHERE id=?1"), [&id], row_to_session)
            .optional()?)
    }

    pub fn mark_read(&self, session_id: &str, through_sequence: i64) -> StoreResult<TaskSession> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
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
        self.session(&session_id)?.ok_or(StoreError::NotFound)
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

    pub fn session_turn_count(&self, session_id: &str) -> StoreResult<i64> {
        let session_id = canonical_uuid(session_id, "sessionId")?;
        Ok(self.connection.query_row(
            "SELECT count(*) FROM session_turn WHERE session_id=?1",
            [&session_id],
            |row| row.get(0),
        )?)
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

/// Removes a pre-v4 development database and its managed task attachments.
/// Credentials, settings files and logs live outside these exact targets and are
/// deliberately left untouched. A future schema is never silently destroyed.
pub fn prepare_database_files(database: &Path, attachments: &Path) -> StoreResult<()> {
    if !database.exists() {
        ensure_real_directory(attachments)?;
        remove_file_if_present(&sqlite_sidecar_path(database, "-wal"))?;
        remove_file_if_present(&sqlite_sidecar_path(database, "-shm"))?;
        reset_managed_attachments(attachments)?;
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
    if version == Some(SCHEMA_VERSION) {
        return Ok(());
    }

    // Validate the exact managed root before deleting an old database. A
    // symlink must never redirect cleanup into an external directory.
    ensure_real_directory(attachments)?;

    for path in [
        database.to_owned(),
        sqlite_sidecar_path(database, "-wal"),
        sqlite_sidecar_path(database, "-shm"),
    ] {
        remove_file_if_present(&path)?;
    }
    reset_managed_attachments(attachments)?;
    Ok(())
}

fn remove_file_if_present(path: &Path) -> StoreResult<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn reset_managed_attachments(attachments: &Path) -> StoreResult<()> {
    ensure_real_directory(attachments)?;
    match fs::remove_dir_all(attachments) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    fs::create_dir_all(attachments)?;
    ensure_real_directory(attachments)?;
    Ok(())
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
    if version.is_some_and(|version| version < SCHEMA_VERSION)
        || (version.is_none() && has_application_tables(connection)?)
    {
        reset_schema(connection)?;
    }
    connection.execute_batch(include_str!("schema.sql"))?;
    connection.execute(
        "INSERT OR IGNORE INTO schema_migration(version,name,checksum,applied_at)
         VALUES(?1,'unified task time and attachments',?2,?3)",
        params![SCHEMA_VERSION, SCHEMA_CHECKSUM, now()],
    )?;
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

fn reset_schema(connection: &Connection) -> StoreResult<()> {
    connection.pragma_update(None, "foreign_keys", "OFF")?;
    let mut statement = connection.prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    )?;
    let tables = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for table in tables {
        let escaped = table.replace('"', "\"\"");
        connection.execute_batch(&format!("DROP TABLE IF EXISTS \"{escaped}\";"))?;
    }
    connection.pragma_update(None, "foreign_keys", "ON")?;
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

fn bump_task_data_revision(transaction: &Transaction<'_>) -> rusqlite::Result<()> {
    transaction.execute(
        "UPDATE task_data_revision SET revision=revision+1 WHERE singleton=1",
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
                "SELECT count(*) FROM task_session WHERE state IN ('queued','running')",
                [],
                |row| row.get(0),
            )?;
            let unread_count: i64 = transaction.query_row(
                "SELECT count(*) FROM task_session WHERE last_agent_sequence > last_read_sequence",
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
                task_session_summaries(transaction, "state IN ('queued','running')", 20)?;
            let (unread_sessions, unread_truncated) = task_session_summaries(
                transaction,
                "last_agent_sequence > last_read_sequence",
                20,
            )?;
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

fn task_session_summaries(
    transaction: &Transaction<'_>,
    filter: &str,
    limit: i64,
) -> rusqlite::Result<(Vec<Value>, bool)> {
    let mut statement = transaction.prepare(&format!(
        "SELECT s.id,s.task_id,t.title,s.state,s.last_agent_sequence,s.last_read_sequence
         FROM task_session s JOIN task t ON t.id=s.task_id WHERE {filter}
         ORDER BY s.updated_at DESC LIMIT ?1"
    ))?;
    let rows = statement
        .query_map([limit + 1], |row| {
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
                "message": "工具结果超过 8 KiB，且不是有效 JSON，原内容已省略。",
            })
            .to_string()
        })
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
           SELECT 1 FROM task_session AS session
           WHERE session.task_id=?1 AND (
             session.state IN ('queued','running') OR EXISTS(
               SELECT 1 FROM session_turn AS turn
               WHERE turn.session_id=session.id AND turn.status IN ('queued','running')
             )
           )
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
    use std::os::unix::fs::symlink;
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
    fn provider_session_mutations_advance_bootstrap_revision() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("Provider", "", None, None, None).unwrap();
        let session = store
            .create_session(&task.id, RuntimeKind::Codex, "/tmp")
            .unwrap();
        let initial_revision = store.revision().unwrap();

        store
            .set_provider_session(&session.id.to_uppercase(), "provider-1")
            .unwrap();
        assert_eq!(store.revision().unwrap(), initial_revision + 1);
        assert_eq!(
            store.bootstrap().unwrap().sessions[0]
                .provider_session_id
                .as_deref(),
            Some("provider-1")
        );

        store
            .clear_provider_session(&session.id.to_uppercase())
            .unwrap();
        assert_eq!(store.revision().unwrap(), initial_revision + 2);
        assert!(
            store.bootstrap().unwrap().sessions[0]
                .provider_session_id
                .is_none()
        );
    }

    #[test]
    fn create_list_from_task_is_atomic_and_unicode_truncates_to_200_characters() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let old_list = store.create_list("旧清单", "orange", None).unwrap();
        let title = format!("新清单{}", "界".repeat(250));
        let task = store
            .create_task(&title, "", Some(&old_list.id), None, None)
            .unwrap();
        let app_revision = store.revision().unwrap();
        let task_revision: i64 = store
            .connection
            .query_row(
                "SELECT revision FROM task_data_revision WHERE singleton=1",
                [],
                |row| row.get(0),
            )
            .unwrap();

        let list = store
            .create_list_from_task(&task.id.to_uppercase())
            .unwrap();

        assert_eq!(list.name.chars().count(), 200);
        assert_eq!(list.name, title.chars().take(200).collect::<String>());
        assert_eq!(list.color, "blue");
        assert!(list.repository_path.is_none());
        assert_eq!(
            store.task(&task.id).unwrap().unwrap().list_id.as_deref(),
            Some(list.id.as_str())
        );
        assert_eq!(store.revision().unwrap(), app_revision + 1);
        let updated_task_revision: i64 = store
            .connection
            .query_row(
                "SELECT revision FROM task_data_revision WHERE singleton=1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(updated_task_revision, task_revision + 1);
        assert!(matches!(
            store.create_list_from_task(&Uuid::new_v4().to_string()),
            Err(StoreError::NotFound)
        ));
        assert!(matches!(
            store.create_list_from_task("not-a-uuid"),
            Err(StoreError::Invalid(_))
        ));
    }

    #[test]
    fn delete_task_cascades_owned_records_and_advances_revisions_once() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("删除任务", "", None, None, None).unwrap();
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
        let session = store
            .create_session(&task.id, RuntimeKind::Codex, "/tmp")
            .unwrap();
        let queued = store
            .send_message(&session.id, &Uuid::new_v4().to_string(), "删除任务")
            .unwrap();
        store
            .finish_turn(
                &queued.turn.id,
                TurnStatus::Completed,
                Some(0),
                Some("完成"),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        assert_eq!(
            store.prepare_delete_task(&task.id).unwrap(),
            vec![attachment]
        );
        let app_revision = store.revision().unwrap();
        let task_revision: i64 = store
            .connection
            .query_row(
                "SELECT revision FROM task_data_revision WHERE singleton=1",
                [],
                |row| row.get(0),
            )
            .unwrap();

        store.delete_task(&task.id.to_uppercase()).unwrap();

        assert!(store.task(&task.id).unwrap().is_none());
        assert!(store.bootstrap().unwrap().task_attachments.is_empty());
        assert!(store.bootstrap().unwrap().sessions.is_empty());
        for table in ["task_session", "session_turn", "session_message"] {
            let sql = format!("SELECT count(*) FROM {table}");
            let count: i64 = store
                .connection
                .query_row(&sql, [], |row| row.get(0))
                .unwrap();
            assert_eq!(count, 0, "{table} should cascade with its task");
        }
        assert_eq!(store.revision().unwrap(), app_revision + 1);
        let updated_task_revision: i64 = store
            .connection
            .query_row(
                "SELECT revision FROM task_data_revision WHERE singleton=1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(updated_task_revision, task_revision + 1);
        assert!(matches!(
            store.delete_task(&task.id),
            Err(StoreError::NotFound)
        ));
    }

    #[test]
    fn delete_task_rejects_queued_or_running_session_without_mutation() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("运行中", "", None, None, None).unwrap();
        let session = store
            .create_session(&task.id, RuntimeKind::Codex, "/tmp")
            .unwrap();
        let queued = store
            .send_message(&session.id, &Uuid::new_v4().to_string(), "运行中")
            .unwrap();
        let revision = store.revision().unwrap();

        assert!(matches!(
            store.prepare_delete_task(&task.id),
            Err(StoreError::Conflict("task_session_active"))
        ));
        assert!(matches!(
            store.delete_task(&task.id),
            Err(StoreError::Conflict("task_session_active"))
        ));
        assert!(store.task(&task.id).unwrap().is_some());
        assert!(store.session(&queued.session.id).unwrap().is_some());
        assert_eq!(store.revision().unwrap(), revision);
    }

    #[test]
    fn fresh_database_round_trips_session_and_unread() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let list = store
            .create_list("产品", "blue", Some("/tmp/repo"))
            .unwrap();
        let task = store
            .create_task(
                "完成原生版",
                "接通后端",
                Some(&list.id),
                None,
                Some("2026-08-08"),
            )
            .unwrap();
        let session = store
            .create_session(&task.id, RuntimeKind::Codex, "/tmp/repo")
            .unwrap();
        let queued = store
            .send_message(
                &session.id,
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
        assert_eq!(store.health().unwrap()["schemaVersion"], 4);
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
    fn prepare_v4_rebuild_removes_only_database_and_managed_attachments() {
        let directory = tempdir().unwrap();
        let database = directory.path().join("todoagent.sqlite3");
        let attachments = directory.path().join("Attachments");
        fs::create_dir_all(&attachments).unwrap();
        fs::write(attachments.join("old-copy"), b"old").unwrap();
        fs::write(directory.path().join("credentials.json"), b"credential").unwrap();
        fs::write(directory.path().join("settings.json"), b"settings").unwrap();
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE schema_migration(version INTEGER PRIMARY KEY,name TEXT NOT NULL,checksum TEXT NOT NULL,applied_at TEXT NOT NULL);
                 INSERT INTO schema_migration VALUES(3,'old','v3','2026-01-01T00:00:00Z');",
            )
            .unwrap();
        drop(connection);
        fs::write(sqlite_sidecar_path(&database, "-wal"), b"wal").unwrap();
        fs::write(sqlite_sidecar_path(&database, "-shm"), b"shm").unwrap();

        prepare_database_files(&database, &attachments).unwrap();

        assert!(!database.exists());
        assert!(!sqlite_sidecar_path(&database, "-wal").exists());
        assert!(!sqlite_sidecar_path(&database, "-shm").exists());
        assert!(attachments.exists());
        assert_eq!(fs::read_dir(&attachments).unwrap().count(), 0);
        assert_eq!(
            fs::read(directory.path().join("credentials.json")).unwrap(),
            b"credential"
        );
        assert_eq!(
            fs::read(directory.path().join("settings.json")).unwrap(),
            b"settings"
        );
    }

    #[test]
    fn prepare_v4_finishes_an_interrupted_reset_when_database_is_already_gone() {
        let directory = tempdir().unwrap();
        let database = directory.path().join("todoagent.sqlite3");
        let attachments = directory.path().join("Attachments");
        fs::create_dir_all(&attachments).unwrap();
        fs::write(attachments.join("orphaned-copy"), b"old").unwrap();
        fs::write(sqlite_sidecar_path(&database, "-wal"), b"stale wal").unwrap();
        fs::write(sqlite_sidecar_path(&database, "-shm"), b"stale shm").unwrap();
        fs::write(directory.path().join("credentials.json"), b"credential").unwrap();
        fs::write(directory.path().join("settings.json"), b"settings").unwrap();
        fs::create_dir_all(directory.path().join("Logs")).unwrap();
        fs::write(directory.path().join("Logs/engine.log"), b"log").unwrap();

        prepare_database_files(&database, &attachments).unwrap();

        assert!(!sqlite_sidecar_path(&database, "-wal").exists());
        assert!(!sqlite_sidecar_path(&database, "-shm").exists());
        assert_eq!(fs::read_dir(&attachments).unwrap().count(), 0);
        assert_eq!(
            fs::read(directory.path().join("credentials.json")).unwrap(),
            b"credential"
        );
        assert_eq!(
            fs::read(directory.path().join("settings.json")).unwrap(),
            b"settings"
        );
        assert_eq!(
            fs::read(directory.path().join("Logs/engine.log")).unwrap(),
            b"log"
        );
    }

    #[test]
    fn attachment_reset_and_reconciliation_reject_symlink_roots() {
        let directory = tempdir().unwrap();
        let external = directory.path().join("external");
        fs::create_dir_all(&external).unwrap();
        let sentinel = external.join("sentinel.txt");
        fs::write(&sentinel, b"keep").unwrap();
        let attachments = directory.path().join("Attachments");
        symlink(&external, &attachments).unwrap();
        let database = directory.path().join("todoagent.sqlite3");

        let reset_error = prepare_database_files(&database, &attachments).unwrap_err();
        assert!(matches!(
            reset_error,
            StoreError::Invalid(_) | StoreError::Io(_)
        ));
        assert_eq!(fs::read(&sentinel).unwrap(), b"keep");

        let store = Store::open(&database).unwrap();
        let reconcile_error = store
            .reconcile_task_attachment_files(&attachments)
            .unwrap_err();
        assert!(matches!(
            reconcile_error,
            StoreError::Invalid(_) | StoreError::Io(_)
        ));
        assert_eq!(fs::read(&sentinel).unwrap(), b"keep");
        assert_eq!(fs::read_dir(&external).unwrap().count(), 1);
    }

    #[test]
    fn prepare_v4_rejects_future_database_without_deleting_it() {
        let directory = tempdir().unwrap();
        let database = directory.path().join("todoagent.sqlite3");
        let attachments = directory.path().join("Attachments");
        fs::create_dir_all(&attachments).unwrap();
        fs::write(attachments.join("keep"), b"keep").unwrap();
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE schema_migration(version INTEGER PRIMARY KEY,name TEXT NOT NULL,checksum TEXT NOT NULL,applied_at TEXT NOT NULL);
                 INSERT INTO schema_migration VALUES(5,'future','v5','2026-01-01T00:00:00Z');",
            )
            .unwrap();
        drop(connection);

        let error = prepare_database_files(&database, &attachments).unwrap_err();

        assert!(matches!(error, StoreError::Invalid(_)));
        assert!(database.exists());
        assert!(attachments.join("keep").exists());
    }

    #[test]
    fn session_create_is_empty_and_same_configuration_replays_without_revision_bump() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store
            .create_task(
                "任务标题",
                "任务备注",
                None,
                Some("2026-08-10"),
                Some("2026-08-12"),
            )
            .unwrap();
        let revision_before = store.revision().unwrap();

        let session = store
            .create_session(&task.id.to_uppercase(), RuntimeKind::Codex, "/tmp")
            .unwrap();
        assert_eq!(session.state, SessionState::Idle);
        assert_eq!(store.revision().unwrap(), revision_before + 1);
        assert_eq!(store.session_turn_count(&session.id).unwrap(), 0);
        let bundle = store.session_bundle(&session.id, 0, 100).unwrap();
        assert!(bundle.messages.is_empty());
        assert!(bundle.active_turn.is_none());

        let replay_revision = store.revision().unwrap();
        let replayed = store
            .create_session(&task.id, RuntimeKind::Codex, "/tmp")
            .unwrap();
        assert_eq!(replayed.id, session.id);
        assert_eq!(store.revision().unwrap(), replay_revision);
        assert!(matches!(
            store.create_session(&task.id, RuntimeKind::Claude, "/tmp"),
            Err(StoreError::Conflict("session_exists"))
        ));
        assert!(matches!(
            store.create_session(&task.id, RuntimeKind::Codex, "/private/tmp"),
            Err(StoreError::Conflict("session_exists"))
        ));

        let queued = store
            .send_message(&session.id, &Uuid::new_v4().to_string(), "用户实际输入")
            .unwrap();
        assert_eq!(queued.prompt, "用户实际输入");
        let bundle = store.session_bundle(&session.id, 0, 100).unwrap();
        assert_eq!(bundle.messages.len(), 1);
        assert_eq!(bundle.messages[0].body, "用户实际输入");
        assert!(!bundle.messages[0].body.contains("任务标题"));
        assert!(!bundle.messages[0].body.contains("2026-08-10"));
        assert!(matches!(
            store.create_session(&task.id, RuntimeKind::Codex, "/tmp"),
            Err(StoreError::Conflict("session_exists"))
        ));
    }

    #[test]
    fn client_message_id_is_idempotent() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("任务", "", None, None, None).unwrap();
        let client_id = Uuid::new_v4().to_string();
        let session = store
            .create_session(&task.id.to_uppercase(), RuntimeKind::Claude, "/tmp")
            .unwrap();
        let first = store
            .send_message(&session.id, &client_id.to_uppercase(), "任务")
            .unwrap();
        let duplicate = store
            .send_message(
                &first.session.id.to_uppercase(),
                &client_id.to_uppercase(),
                "任务",
            )
            .unwrap();
        assert_eq!(first.turn.id, duplicate.turn.id);
        assert!(!duplicate.is_new);
        assert_eq!(first.session.task_id, task.id);
        assert_eq!(
            store
                .session(&first.session.id.to_uppercase())
                .unwrap()
                .unwrap()
                .id,
            first.session.id
        );
    }

    #[test]
    fn only_one_active_turn_is_allowed_per_session() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let task = store.create_task("任务", "", None, None, None).unwrap();
        let session = store
            .create_session(&task.id, RuntimeKind::Cursor, "/tmp")
            .unwrap();
        store
            .send_message(&session.id, &Uuid::new_v4().to_string(), "任务")
            .unwrap();
        let error = store
            .send_message(&session.id, &Uuid::new_v4().to_string(), "继续")
            .unwrap_err();
        assert!(matches!(error, StoreError::Conflict("session_busy")));
    }

    #[test]
    fn older_schema_is_rebuilt_as_empty_v4() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("todoagent.sqlite3");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE schema_migration(version INTEGER PRIMARY KEY,name TEXT NOT NULL,checksum TEXT NOT NULL,applied_at TEXT NOT NULL);
                 INSERT INTO schema_migration VALUES(2,'session model','v2','2026-01-01T00:00:00Z');
                 CREATE TABLE app_revision(singleton INTEGER PRIMARY KEY CHECK(singleton=1),revision INTEGER NOT NULL);
                 INSERT INTO app_revision VALUES(1,0);
                 CREATE TABLE chat_session(id TEXT PRIMARY KEY,title TEXT NOT NULL DEFAULT '',created_at TEXT NOT NULL,updated_at TEXT NOT NULL,archived_at TEXT);
                 CREATE TABLE chat_message(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,sequence INTEGER NOT NULL,role TEXT NOT NULL,body TEXT NOT NULL,payload_json TEXT,created_at TEXT NOT NULL,UNIQUE(session_id,sequence));",
            )
            .unwrap();
        drop(connection);
        let store = Store::open(&path).unwrap();
        assert_eq!(store.health().unwrap()["schemaVersion"], 4);
        let columns = store
            .connection
            .prepare("PRAGMA table_info(chat_message)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert!(columns.contains(&"turn_id".to_owned()));
        assert!(columns.contains(&"updated_at".to_owned()));
        let task_columns = store
            .connection
            .prepare("PRAGMA table_info(task)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert!(task_columns.contains(&"execution_date".to_owned()));
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
    fn assistant_five_task_tools_execute_happy_paths() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let list = store.create_list("生活", "orange", None).unwrap();
        let queued = running_assistant_turn(&store, "五工具");

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
                "INSERT INTO task_session(id,task_id,runtime_kind,working_directory,state,last_agent_sequence,last_read_sequence,created_at,updated_at)
                 VALUES(?1,?2,'codex','/tmp','running',3,1,?3,?3)",
                params![Uuid::new_v4().to_string(), open_tasks[0].id, timestamp],
            )
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
            store
                .create_list(
                    &format!("清单 {index} {}", "名".repeat(500)),
                    "blue",
                    Some(&format!(
                        "/Users/example/TopSecret/{index}/{}",
                        "目录/".repeat(500)
                    )),
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
