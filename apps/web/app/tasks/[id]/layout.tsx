export default function TaskLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="page">
      <div className="page-in task-thread-page-in">{children}</div>
    </div>
  );
}
