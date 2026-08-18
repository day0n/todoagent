import { SiteNav } from "./site-nav";

const githubUrl = "https://github.com/day0n/todoagent";
const downloadUrl = `${githubUrl}/releases/tag/v0.1.0`;
const buildUrl = `${githubUrl}#本地构建与运行`;

const navLinks = [
  { href: "#terminal", label: "终端" },
  { href: "#agents", label: "Agent" },
  { href: "#todoagent", label: "TodoAgent" },
  { href: githubUrl, label: "GitHub", external: true },
];

const runtimes = ["Codex", "Claude Code", "Cursor Agent", "Kiro CLI"];

export default function Home() {
  return (
    <main>
      <SiteNav downloadUrl={downloadUrl} links={navLinks} />

      <header className="hero" id="top">
        <div className="hero-copy">
          <p className="kicker">开发预览 · macOS 26+</p>
          <h1>
            一个任务。
            <br />
            一条终端。
            <br />
            一个 Agent。
          </h1>
          <p className="lede">
            打开任务，就绑定一条还活着的终端。在这个目录里启动 Codex、Claude Code、Cursor Agent 或
            Kiro CLI。清单交给 TodoAgent。
          </p>
          <div className="actions">
            <a className="button primary" href={downloadUrl} target="_blank" rel="noreferrer">
              下载开发预览
            </a>
            <a className="button ghost" href={buildUrl} target="_blank" rel="noreferrer">
              从源码构建
            </a>
          </div>
          <p className="download-note">
            macOS 26+ · Apple 芯片 · ad-hoc 签名，Gatekeeper 会拦截首次打开。
          </p>
        </div>
        <aside className="hero-meta" aria-label="产品要点">
          <p>每个任务一条 Ghostty PTY</p>
          <p>启动你已经在用的 CLI</p>
          <p>清单由 TodoAgent 来管</p>
          <p>Apple 芯片 · 本地优先</p>
        </aside>
      </header>

      <section className="stage" id="terminal" aria-label="任务绑定的 Agent 终端">
        <figure className="shot shot-hero">
          <img
            src="/shots/workspace.png"
            alt="左侧任务栏，右侧是这条任务绑定的本机终端"
            width={2000}
            height={1295}
          />
          <figcaption>
            <span>Agent 终端</span>
            <span>每个任务自己的 PTY。切走也不会断。</span>
          </figcaption>
        </figure>
      </section>

      <section className="steps" aria-label="工作台怎么用">
        <article>
          <p className="step-index">01</p>
          <h2>把终端绑到任务上。</h2>
          <p>
            打开任务，主窗口就挂上它自己的 Ghostty PTY。收起、换任务、再回来——进程和滚屏都还在。
          </p>
        </article>
        <article id="agents">
          <p className="step-index">02</p>
          <h2>在这条终端里启动 Agent。</h2>
          <p>
            启动这台 Mac 上已经装好的 Coding Agent，工作目录就是这个任务的目录。TUI
            还是它们自己，TodoAgent 不会包成另一层对话。
          </p>
          <ul className="runtime-list">
            {runtimes.map((runtime) => (
              <li key={runtime}>{runtime}</li>
            ))}
          </ul>
        </article>
        <article>
          <p className="step-index">03</p>
          <h2>清单交给 TodoAgent。</h2>
          <p>
            TodoAgent 助手负责创建、查找和安排任务。它没有
            shell，也不能派发 Coding Agent。清单和终端分开，是故意的。
          </p>
        </article>
      </section>

      <section className="pair" id="todoagent" aria-label="TodoAgent 助手">
        <figure className="shot">
          <img
            src="/shots/board.png"
            alt="TodoAgent 助手根据一句话创建并安排到今天的任务"
            width={2000}
            height={1295}
          />
        </figure>
        <div className="pair-copy">
          <p className="kicker">TodoAgent</p>
          <h2>管清单的助手。不管终端。</h2>
          <p>
            告诉 TodoAgent 今天要做什么。它写下任务、排好日期，不去碰已经绑好的终端。Coding Agent
            继续用自己的账号和自己的 TUI。
          </p>
        </div>
      </section>

      <section className="pair pair-reverse" aria-label="任务库存">
        <figure className="shot">
          <img
            src="/shots/lists.png"
            alt="TodoAgent 的今天、任务库存和清单"
            width={2000}
            height={1295}
          />
        </figure>
        <div className="pair-copy">
          <p className="kicker">会话跟着任务走</p>
          <h2>每一条，都是开工的入口。</h2>
          <p>
            今天、清单、全部任务，只是找任务的不同入口。终端和 Agent
            属于这条任务，不属于你从哪个视图点进去。
          </p>
        </div>
      </section>

      <section className="close">
        <img src="/todoagent-icon.png" alt="" width={72} height={72} />
        <p className="kicker">开发预览</p>
        <h2>先用这个 0.1.0 预览。</h2>
        <p>
          macOS 26+，Apple 芯片。任务和会话元数据留在本机 SQLite。预览 DMG 已经可以下载；它是
          ad-hoc 签名，尚未公证。
        </p>
        <div className="actions">
          <a className="button primary" href={downloadUrl} target="_blank" rel="noreferrer">
            下载 0.1.0
          </a>
          <a className="button ghost" href={buildUrl} target="_blank" rel="noreferrer">
            从源码构建
          </a>
        </div>
      </section>

      <footer>
        <a className="footer-brand" href="#top">
          <img src="/todoagent-icon.png" alt="" width={24} height={24} />
          <span>TodoAgent</span>
        </a>
        <p>一个任务。一条终端。一个 Agent。</p>
        <div className="footer-links">
          <a href={downloadUrl} target="_blank" rel="noreferrer">
            下载
          </a>
          <a href={githubUrl} target="_blank" rel="noreferrer">
            GitHub
          </a>
          <a href={`${githubUrl}/blob/master/README.md`} target="_blank" rel="noreferrer">
            文档
          </a>
          <a href={`${githubUrl}/issues`} target="_blank" rel="noreferrer">
            议题
          </a>
        </div>
        <div className="footer-legal">
          <span>© 2026 TodoAgent。</span>
          <span>源码公开。产品名称为其各自所有者的商标。</span>
        </div>
      </footer>
    </main>
  );
}
