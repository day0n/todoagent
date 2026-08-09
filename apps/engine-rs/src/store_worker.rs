use std::path::Path;
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};

use thiserror::Error;
use tokio::sync::oneshot;

use crate::store::{Store, StoreError};

type StoreJob = Box<dyn FnOnce(&mut Store) + Send + 'static>;

enum Command {
    Call(StoreJob),
    Shutdown(oneshot::Sender<()>),
}

struct WorkerState {
    sender: Mutex<Option<mpsc::Sender<Command>>>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

/// Owns the application's single SQLite connection on a dedicated OS thread.
///
/// `rusqlite` work can perform filesystem I/O and wait on SQLite locks. Routing
/// every operation through this worker keeps that work off the current-thread
/// Tokio executor while preserving the Store's single-connection ordering.
#[derive(Clone)]
pub struct StoreWorker {
    state: Arc<WorkerState>,
}

#[derive(Debug, Error)]
pub enum StoreWorkerError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error("database worker is unavailable")]
    Closed,
    #[error("database worker response was cancelled")]
    ResponseCancelled,
    #[error("database worker thread failed to start: {0}")]
    Spawn(#[from] std::io::Error),
    #[error("database worker thread panicked")]
    Panicked,
}

impl StoreWorker {
    pub fn open(path: &Path) -> Result<Self, StoreWorkerError> {
        let (command_tx, command_rx) = mpsc::channel::<Command>();
        let (startup_tx, startup_rx) = mpsc::sync_channel(1);
        let database_path = path.to_owned();
        let thread = thread::Builder::new()
            .name("todoagent-sqlite".to_owned())
            .spawn(move || {
                let mut store = match Store::open(&database_path) {
                    Ok(store) => {
                        let _ = startup_tx.send(Ok(()));
                        store
                    }
                    Err(error) => {
                        let _ = startup_tx.send(Err(error));
                        return;
                    }
                };

                while let Ok(command) = command_rx.recv() {
                    match command {
                        Command::Call(job) => job(&mut store),
                        Command::Shutdown(done) => {
                            // Dropping Store here closes SQLite before shutdown is
                            // acknowledged to the async runtime.
                            drop(store);
                            let _ = done.send(());
                            return;
                        }
                    }
                }
            })?;

        match startup_rx.recv() {
            Ok(Ok(())) => Ok(Self {
                state: Arc::new(WorkerState {
                    sender: Mutex::new(Some(command_tx)),
                    thread: Mutex::new(Some(thread)),
                }),
            }),
            Ok(Err(error)) => {
                let _ = thread.join();
                Err(StoreWorkerError::Store(error))
            }
            Err(_) => {
                let _ = thread.join();
                Err(StoreWorkerError::Closed)
            }
        }
    }

    pub async fn call<T, F>(&self, operation: F) -> Result<T, StoreWorkerError>
    where
        T: Send + 'static,
        F: FnOnce(&mut Store) -> Result<T, StoreError> + Send + 'static,
    {
        let (result_tx, result_rx) = oneshot::channel();
        let command = Command::Call(Box::new(move |store| {
            let _ = result_tx.send(operation(store));
        }));
        self.sender()?
            .send(command)
            .map_err(|_| StoreWorkerError::Closed)?;
        result_rx
            .await
            .map_err(|_| StoreWorkerError::ResponseCancelled)?
            .map_err(StoreWorkerError::Store)
    }

    /// Stops accepting new work, closes SQLite on its owner thread, and joins
    /// that thread without blocking the async executor.
    pub async fn shutdown(&self) -> Result<(), StoreWorkerError> {
        let sender = self
            .state
            .sender
            .lock()
            .map_err(|_| StoreWorkerError::Closed)?
            .take();

        let mut acknowledgement = Ok(());
        if let Some(sender) = sender {
            let (done_tx, done_rx) = oneshot::channel();
            if sender.send(Command::Shutdown(done_tx)).is_ok() {
                acknowledgement = done_rx
                    .await
                    .map_err(|_| StoreWorkerError::ResponseCancelled);
            } else {
                acknowledgement = Err(StoreWorkerError::Closed);
            }
        }

        let thread = self
            .state
            .thread
            .lock()
            .map_err(|_| StoreWorkerError::Closed)?
            .take();
        if let Some(thread) = thread {
            tokio::task::spawn_blocking(move || thread.join())
                .await
                .map_err(|_| StoreWorkerError::Panicked)?
                .map_err(|_| StoreWorkerError::Panicked)?;
        }
        acknowledgement
    }

    fn sender(&self) -> Result<mpsc::Sender<Command>, StoreWorkerError> {
        self.state
            .sender
            .lock()
            .map_err(|_| StoreWorkerError::Closed)?
            .as_ref()
            .cloned()
            .ok_or(StoreWorkerError::Closed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "current_thread")]
    async fn calls_are_serialized_on_the_database_thread() {
        let directory = tempfile::tempdir().unwrap();
        let worker = StoreWorker::open(&directory.path().join("worker.sqlite3")).unwrap();
        let async_thread = thread::current().id();

        let database_thread = worker
            .call(move |store| {
                let _ = store.health()?;
                Ok(thread::current().id())
            })
            .await
            .unwrap();
        assert_ne!(async_thread, database_thread);

        let list = worker
            .call(|store| store.create_list("工作", "blue", None))
            .await
            .unwrap();
        let observed = worker
            .call(move |store| {
                Ok(store
                    .bootstrap()?
                    .lists
                    .into_iter()
                    .any(|candidate| candidate.id == list.id))
            })
            .await
            .unwrap();
        assert!(observed);

        worker.shutdown().await.unwrap();
        let error = worker.call(|store| store.health()).await.unwrap_err();
        assert!(matches!(error, StoreWorkerError::Closed));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn cancelling_a_waiter_does_not_poison_the_worker() {
        let directory = tempfile::tempdir().unwrap();
        let worker = StoreWorker::open(&directory.path().join("cancel.sqlite3")).unwrap();
        let pending_worker = worker.clone();
        let pending = tokio::spawn(async move {
            pending_worker
                .call(|store| {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                    store.health()
                })
                .await
        });
        tokio::task::yield_now().await;
        pending.abort();

        let health = worker.call(|store| store.health()).await.unwrap();
        assert_eq!(health["ok"], true);
        worker.shutdown().await.unwrap();
    }
}
