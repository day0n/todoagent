use std::path::Path;

use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::json;
use uuid::Uuid;

use crate::models::{List, Runtime, RuntimeKind, Snapshot, Task, TaskStatus};

pub struct Store {
    connection: Connection,
}

impl Store {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        let connection = Connection::open(path)?;
        connection.execute_batch(include_str!("schema.sql"))?;
        let count: i64 =
            connection.query_row("SELECT count(*) FROM schema_version", [], |row| row.get(0))?;
        if count == 0 {
            connection.execute(
                "INSERT INTO schema_version(version, applied_at) VALUES(1, ?1)",
                [Utc::now().to_rfc3339()],
            )?;
        }
        let store = Self { connection };
        store.reconcile_interrupted_runs()?;
        Ok(store)
    }

    pub fn snapshot(&self) -> rusqlite::Result<Snapshot> {
        Ok(Snapshot {
            lists: self.lists()?,
            tasks: self.tasks()?,
        })
    }

    pub fn create_list(
        &self,
        name: &str,
        color: &str,
        repository_path: Option<&str>,
    ) -> rusqlite::Result<List> {
        let now = Utc::now().to_rfc3339();
        let list = List {
            id: Uuid::new_v4().to_string(),
            name: name.to_owned(),
            color: color.to_owned(),
            repository_path: repository_path.map(str::to_owned),
            archived_at: None,
            created_at: now.clone(),
            updated_at: now,
        };
        self.connection.execute(
            "INSERT INTO list(id,name,color,repository_path,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6)",
            params![list.id, list.name, list.color, list.repository_path, list.created_at, list.updated_at],
        )?;
        Ok(list)
    }

    pub fn create_task(
        &self,
        title: &str,
        list_id: Option<&str>,
        due_date: Option<&str>,
    ) -> rusqlite::Result<Task> {
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
                return Err(rusqlite::Error::QueryReturnedNoRows);
            }
        }
        let now = Utc::now().to_rfc3339();
        let task = Task {
            id: Uuid::new_v4().to_string(),
            list_id: list_id.map(str::to_owned),
            title: title.to_owned(),
            note: String::new(),
            status: TaskStatus::Todo,
            due_date: due_date.map(str::to_owned),
            needs_kind: None,
            needs_text: None,
            runtime_kind: None,
            working_directory: None,
            active_run_id: None,
            created_at: now.clone(),
            updated_at: now,
        };
        self.connection.execute(
            "INSERT INTO task(id,list_id,title,note,status,due_date,created_at,updated_at) VALUES(?1,?2,?3,'','todo',?4,?5,?6)",
            params![task.id, task.list_id, task.title, task.due_date, task.created_at, task.updated_at],
        )?;
        Ok(task)
    }

    pub fn set_task_status(&self, id: &str, status: TaskStatus) -> rusqlite::Result<Task> {
        let now = Utc::now().to_rfc3339();
        let changed = self.connection.execute(
            "UPDATE task SET status=?1, needs_kind=CASE WHEN ?1='needs_you' THEN needs_kind ELSE NULL END, needs_text=CASE WHEN ?1='needs_you' THEN needs_text ELSE NULL END, updated_at=?2 WHERE id=?3",
            params![status.as_str(), now, id],
        )?;
        if changed == 0 {
            return Err(rusqlite::Error::QueryReturnedNoRows);
        }
        self.task(id)?.ok_or(rusqlite::Error::QueryReturnedNoRows)
    }

    fn lists(&self) -> rusqlite::Result<Vec<List>> {
        let mut statement = self.connection.prepare(
            "SELECT id,name,color,repository_path,archived_at,created_at,updated_at FROM list WHERE archived_at IS NULL ORDER BY created_at",
        )?;
        statement
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
            .collect()
    }

    fn tasks(&self) -> rusqlite::Result<Vec<Task>> {
        let mut statement = self.connection.prepare(
            "SELECT id,list_id,title,note,status,due_date,needs_kind,needs_text,runtime_kind,working_directory,active_run_id,created_at,updated_at FROM task ORDER BY updated_at DESC",
        )?;
        statement.query_map([], row_to_task)?.collect()
    }

    fn task(&self, id: &str) -> rusqlite::Result<Option<Task>> {
        self.connection.query_row(
            "SELECT id,list_id,title,note,status,due_date,needs_kind,needs_text,runtime_kind,working_directory,active_run_id,created_at,updated_at FROM task WHERE id=?1",
            [id], row_to_task,
        ).optional()
    }

    fn reconcile_interrupted_runs(&self) -> rusqlite::Result<()> {
        let now = Utc::now().to_rfc3339();
        self.connection.execute(
            "UPDATE run SET status='failed', error='TodoAgent 上次退出时任务仍在运行', ended_at=?1 WHERE status='running'",
            [&now],
        )?;
        self.connection.execute(
            "UPDATE task SET status='needs_you', needs_kind='failed', needs_text='TodoAgent 上次退出时任务仍在运行', active_run_id=NULL, updated_at=?1 WHERE status='running'",
            [&now],
        )?;
        Ok(())
    }

    pub fn health(&self) -> rusqlite::Result<serde_json::Value> {
        let version: i64 = self.connection.query_row(
            "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1",
            [],
            |row| row.get(0),
        )?;
        Ok(json!({ "ok": true, "schemaVersion": version }))
    }

    pub fn save_runtime(&self, runtime: &Runtime) -> rusqlite::Result<()> {
        self.connection.execute(
            "INSERT INTO runtime(kind,executable,version,status,detected_at,verified_at,verify_error)
             VALUES(?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(kind) DO UPDATE SET executable=excluded.executable,version=excluded.version,
             status=excluded.status,detected_at=excluded.detected_at,verified_at=excluded.verified_at,
             verify_error=excluded.verify_error",
            params![
                runtime.kind.as_str(),
                runtime.executable,
                runtime.version,
                runtime.status,
                runtime.detected_at,
                runtime.verified_at,
                runtime.verify_error
            ],
        )?;
        Ok(())
    }

    pub fn runtime(&self, kind: RuntimeKind) -> rusqlite::Result<Option<Runtime>> {
        self.connection
            .query_row(
                "SELECT kind,executable,version,status,detected_at,verified_at,verify_error FROM runtime WHERE kind=?1",
                [kind.as_str()],
                row_to_runtime,
            )
            .optional()
    }

    pub fn runtimes(&self) -> rusqlite::Result<Vec<Runtime>> {
        let mut statement = self.connection.prepare(
            "SELECT kind,executable,version,status,detected_at,verified_at,verify_error FROM runtime ORDER BY kind",
        )?;
        statement.query_map([], row_to_runtime)?.collect()
    }
}

fn row_to_runtime(row: &rusqlite::Row<'_>) -> rusqlite::Result<Runtime> {
    let raw_kind: String = row.get(0)?;
    let kind = RuntimeKind::parse(&raw_kind).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            0,
            rusqlite::types::Type::Text,
            format!("unknown runtime kind {raw_kind}").into(),
        )
    })?;
    Ok(Runtime {
        kind,
        executable: row.get(1)?,
        version: row.get(2)?,
        status: row.get(3)?,
        detected_at: row.get(4)?,
        verified_at: row.get(5)?,
        verify_error: row.get(6)?,
    })
}

fn row_to_task(row: &rusqlite::Row<'_>) -> rusqlite::Result<Task> {
    let raw_status: String = row.get(4)?;
    let status = TaskStatus::parse(&raw_status).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            4,
            rusqlite::types::Type::Text,
            format!("unknown task status {raw_status}").into(),
        )
    })?;
    Ok(Task {
        id: row.get(0)?,
        list_id: row.get(1)?,
        title: row.get(2)?,
        note: row.get(3)?,
        status,
        due_date: row.get(5)?,
        needs_kind: row.get(6)?,
        needs_text: row.get(7)?,
        runtime_kind: row.get(8)?,
        working_directory: row.get(9)?,
        active_run_id: row.get(10)?,
        created_at: row.get(11)?,
        updated_at: row.get(12)?,
    })
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn fresh_database_round_trips_list_and_task() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        let list = store
            .create_list("产品", "blue", Some("/tmp/repo"))
            .unwrap();
        let task = store
            .create_task("完成原生版", Some(&list.id), Some("2026-08-08"))
            .unwrap();
        let review = store.set_task_status(&task.id, TaskStatus::Review).unwrap();
        let snapshot = store.snapshot().unwrap();

        assert_eq!(snapshot.lists, vec![list]);
        assert_eq!(snapshot.tasks, vec![review]);
        assert_eq!(store.health().unwrap()["schemaVersion"], 1);
    }

    #[test]
    fn task_refuses_an_unknown_list() {
        let directory = tempdir().unwrap();
        let store = Store::open(&directory.path().join("todoagent.sqlite3")).unwrap();
        assert!(
            store
                .create_task("不会落库", Some("missing"), None)
                .is_err()
        );
        assert!(store.snapshot().unwrap().tasks.is_empty());
    }
}
