import Link from "next/link";
import { IconBack } from "../../components/icons.tsx";

export default function SettingsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="page">
      <div className="page-in settings-page-in">
        <Link href="/" className="backlink">
          <IconBack />
          返回任务
        </Link>
        {children}
      </div>
    </div>
  );
}
