const githubUrl = "https://github.com/day0n/todoagent";
const buildUrl = `${githubUrl}#本地构建与运行`;

const runtimes = ["Codex", "Claude Code", "Cursor Agent", "Kiro CLI"];

function AppPreview() {
  return (
    <div className="preview-shell" aria-label="TodoAgent product preview">
      <div className="window-bar">
        <div className="traffic-lights" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        <span className="window-title">TodoAgent</span>
        <span className="window-status"><i /> Local</span>
      </div>

      <div className="app-frame">
        <aside className="app-sidebar">
          <div className="sidebar-date">Friday, August 16</div>
          <div className="sidebar-item active"><span className="sidebar-symbol">☀</span> Today <b>3</b></div>
          <div className="sidebar-item"><span className="sidebar-symbol">✓</span> All Tasks <b>8</b></div>
          <div className="sidebar-label">LISTS</div>
          <div className="sidebar-item"><span className="list-dot blue" /> TodoAgent</div>
          <div className="sidebar-item"><span className="list-dot purple" /> OpenCreator</div>
          <div className="sidebar-footer"><span className="local-dot" /> Ready on this Mac</div>
        </aside>

        <section className="task-rail">
          <header>
            <div>
              <span className="eyebrow">TODAY</span>
              <h2>Make the work visible.</h2>
            </div>
            <span className="demo-add" aria-hidden="true">+</span>
          </header>
          <article className="task-card selected">
            <span className="task-check" />
            <div><strong>Polish the public preview</strong><small>TodoAgent · today</small></div>
            <span className="run-state">Running</span>
          </article>
          <article className="task-card">
            <span className="task-check" />
            <div><strong>Review terminal recovery</strong><small>TodoAgent · today</small></div>
          </article>
          <article className="task-card done">
            <span className="task-check checked">✓</span>
            <div><strong>Shape the launch story</strong><small>Completed</small></div>
          </article>
        </section>

        <section className="terminal-pane">
          <div className="terminal-toolbar">
            <span>Polish the public preview</span>
            <div><span className="terminal-pill">Codex</span><span className="toolbar-dot">•••</span></div>
          </div>
          <div className="terminal-copy" aria-hidden="true">
            <p><span className="prompt">~</span> codex</p>
            <p className="terminal-muted">╭──────────────────────────────────────╮</p>
            <p><span className="terminal-accent">›</span> What are we working on?</p>
            <p className="terminal-bright">  Refine the TodoAgent launch experience</p>
            <p className="terminal-muted">  using the existing macOS workspace.</p>
            <p className="terminal-spacer"> </p>
            <p><span className="terminal-success">✓</span> Read the current product surface</p>
            <p><span className="terminal-success">✓</span> Kept the task workspace attached</p>
            <p><span className="terminal-accent">●</span> Working in the real project directory</p>
            <p className="cursor-line"><span>›</span><i /></p>
          </div>
          <div className="terminal-footer"><span>~/Desktop/todoagent</span><span><i /> Session active</span></div>
        </section>
      </div>
    </div>
  );
}

export default function Home() {
  return (
    <main>
      <nav className="site-nav" aria-label="Primary navigation">
        <a className="brand" href="#top" aria-label="TodoAgent home">
          <img src="/todoagent-icon.png" alt="" />
          <span>TodoAgent</span>
        </a>
        <div className="nav-links">
          <a href="#overview">Overview</a>
          <a href="#experience">Experience</a>
          <a href="#privacy">Privacy</a>
          <a href={githubUrl} target="_blank" rel="noreferrer">GitHub</a>
        </div>
        <a className="nav-cta" href={githubUrl} target="_blank" rel="noreferrer">View preview</a>
      </nav>

      <section className="hero" id="top">
        <div className="aurora" aria-hidden="true" />
        <div className="hero-copy">
          <div className="preview-badge"><span /> Developer preview for macOS</div>
          <h1>Your work.<br /><span>All in one place.</span></h1>
          <p>
            Tasks, project directories, and the coding agents you already use—together in one native workspace.
          </p>
          <div className="hero-actions">
            <a className="button primary" href={githubUrl} target="_blank" rel="noreferrer">Explore on GitHub <span>↗</span></a>
            <a className="button secondary" href="#experience">See how it works <span>↓</span></a>
          </div>
          <div className="hero-note">Built for Apple silicon · macOS 26+</div>
        </div>

        <div className="preview-wrap">
          <AppPreview />
        </div>
      </section>

      <section className="first-story" id="experience" aria-label="Product introduction">
        <p className="section-kicker">A workspace that keeps up</p>
        <h2>Think in tasks.<br />Work in terminals.</h2>
        <p className="section-intro">
          TodoAgent gives every task a place to think, a directory to work in, and a terminal that stays alive while you move on.
        </p>
      </section>

      <section className="dark-story" id="overview">
        <div className="dark-glow" aria-hidden="true" />
        <div className="story-heading reveal">
          <p className="section-kicker light">One task. One live terminal.</p>
          <h2>Leave the process running.<br /><span>Keep the context close.</span></h2>
          <p>
            Open a task in its own Ghostty-powered PTY. Move between tasks without stopping the command, agent, or shell that is still working.
          </p>
        </div>

        <div className="continuity-demo reveal" aria-label="TodoAgent task continuity illustration">
          <div className="demo-task-list">
            <div className="demo-list-header"><span>Today</span><small>3 tasks</small></div>
            <div className="demo-task active"><i /><span>Prepare public preview<small>Codex · active</small></span><b>01</b></div>
            <div className="demo-task"><i /><span>Verify session restore<small>Claude Code · ready</small></span><b>02</b></div>
            <div className="demo-task"><i /><span>Review local data flow<small>Cursor Agent · idle</small></span><b>03</b></div>
          </div>
          <div className="demo-terminal">
            <div className="demo-terminal-bar">
              <div><span className="chevron">‹</span><strong>Prepare public preview</strong></div>
              <div className="agent-chip"><i /> Codex</div>
            </div>
            <div className="demo-code">
              <p><span className="green">➜</span> <span className="blue-text">todoagent</span> codex</p>
              <p className="dim">Reading the current workspace…</p>
              <p><span className="success-mark">✓</span> Task context loaded</p>
              <p><span className="success-mark">✓</span> Working directory retained</p>
              <p><span className="spin-mark">●</span> Refining the launch experience</p>
              <div className="code-progress"><span /></div>
            </div>
            <div className="demo-status"><span>~/Desktop/todoagent</span><span><i /> PTY retained</span></div>
          </div>
        </div>
      </section>

      <section className="runtime-story">
        <div className="runtime-copy reveal">
          <p className="section-kicker">Bring the tools you trust</p>
          <h2>Your agents.<br /><span>Still themselves.</span></h2>
          <p>
            TodoAgent detects supported Coding Agent CLIs already installed on your Mac and opens their native terminal experience in the right project directory.
          </p>
          <div className="runtime-pills" aria-label="Supported coding agent runtimes">
            {runtimes.map((runtime, index) => (
              <span key={runtime}><i>{index + 1}</i>{runtime}<b>Ready</b></span>
            ))}
          </div>
        </div>
        <div className="runtime-orbit reveal" aria-hidden="true">
          <div className="orbit-glow" />
          <div className="orbit-core"><img src="/todoagent-icon.png" alt="" /></div>
          <span className="orbit-node node-one">C</span>
          <span className="orbit-node node-two">Cl</span>
          <span className="orbit-node node-three">Cu</span>
          <span className="orbit-node node-four">K</span>
          <div className="orbit-line line-one" />
          <div className="orbit-line line-two" />
          <div className="orbit-line line-three" />
          <div className="orbit-line line-four" />
        </div>
      </section>

      <section className="feature-section">
        <div className="feature-heading reveal">
          <p className="section-kicker">Made for the everyday</p>
          <h2>Quietly powerful.<br />Deliberately familiar.</h2>
        </div>

        <div className="feature-grid">
          <article className="feature-card today-card reveal">
            <div className="card-copy">
              <p className="feature-number">01</p>
              <h3>Today, at a glance.</h3>
              <p>Keep the work that matters now in the main window—and a native menu bar view that is always close.</p>
            </div>
            <div className="menubar-demo" aria-hidden="true">
              <div className="menubar-top"><span>9:41</span><span>⌁ &nbsp; ◉ &nbsp; ☀</span></div>
              <div className="menubar-popover">
                <div><strong>Today</strong><span>Friday, August 16</span></div>
                <p><i /> Polish the public preview</p>
                <p><i /> Review terminal recovery</p>
                <p className="complete"><i>✓</i> Shape the launch story</p>
                <span className="popover-action">Open TodoAgent</span>
              </div>
            </div>
          </article>

          <article className="feature-card resume-card reveal">
            <div className="card-copy">
              <p className="feature-number">02</p>
              <h3>Resume with intent.</h3>
              <p>Verified managed runs can return to the same provider conversation after TodoAgent restarts.</p>
            </div>
            <div className="resume-demo" aria-hidden="true">
              <div className="resume-line"><span className="resume-icon">↗</span><div><strong>Provider session</strong><small>Verified and registered</small></div><b>Active</b></div>
              <div className="resume-connector"><span /><span /><span /></div>
              <div className="resume-line bottom"><span className="resume-icon">↻</span><div><strong>Resume available</strong><small>Same conversation · same directory</small></div><b>Ready</b></div>
            </div>
          </article>

          <article className="feature-card assistant-card reveal">
            <div className="card-copy">
              <p className="feature-number">03</p>
              <h3>An assistant for the task list.</h3>
              <p>Use the optional Gemini assistant to find, create, update, and organize TodoAgent tasks—without giving it shell access.</p>
            </div>
            <div className="assistant-demo" aria-hidden="true">
              <div className="assistant-bubble user">What should I focus on today?</div>
              <div className="assistant-bubble agent"><span className="tiny-mark">TA</span><p>You have two active tasks. “Polish the public preview” is already running.</p></div>
              <div className="assistant-input"><span>Ask about your tasks…</span><b>↑</b></div>
            </div>
          </article>

          <article className="feature-card native-card reveal">
            <div className="card-copy">
              <p className="feature-number">04</p>
              <h3>Native from end to end.</h3>
              <p>SwiftUI and AppKit on the surface. Ghostty for the terminal. A compact Rust engine underneath. No local web server.</p>
            </div>
            <div className="native-stack" aria-hidden="true">
              <div><span>Interface</span><strong>SwiftUI + AppKit</strong><i>Native</i></div>
              <div><span>Terminal</span><strong>Ghostty PTY</strong><i>Live</i></div>
              <div><span>Engine</span><strong>Rust + SQLite</strong><i>Local</i></div>
            </div>
          </article>
        </div>
      </section>

      <section className="privacy-story" id="privacy">
        <div className="privacy-orb" aria-hidden="true"><span /><i /><b /></div>
        <div className="privacy-copy reveal">
          <p className="section-kicker light">Local-first by design</p>
          <h2>Your workspace<br /><span>belongs on your Mac.</span></h2>
          <p>
            Tasks, attachments, and session metadata live in local SQLite. TodoAgent does not turn your terminal output into another chat archive.
          </p>
          <div className="privacy-facts">
            <div><strong>Local storage</strong><span>Task data and metadata stay on device.</span></div>
            <div><strong>Your accounts</strong><span>Coding agents keep their own identity and permissions.</span></div>
            <div><strong>Clear boundaries</strong><span>The optional Gemini assistant has no shell or agent-dispatch access.</span></div>
          </div>
          <p className="privacy-note">
            Coding agents and the optional Gemini assistant may use their own network services when you invoke them. Gemini requires your own API key.
          </p>
        </div>
      </section>

      <section className="preview-cta">
        <img src="/todoagent-icon.png" alt="TodoAgent app icon" />
        <p className="section-kicker">Developer preview</p>
        <h2>Make room for<br />the work that matters.</h2>
        <p>TodoAgent is being built in public for macOS 26+ on Apple silicon.</p>
        <div className="hero-actions">
          <a className="button primary" href={githubUrl} target="_blank" rel="noreferrer">View on GitHub <span>↗</span></a>
          <a className="button secondary" href={buildUrl} target="_blank" rel="noreferrer">Build the preview <span>↗</span></a>
        </div>
        <div className="availability-note">Signed and notarized public downloads are not available yet.</div>
      </section>

      <footer>
        <a className="footer-brand" href="#top"><img src="/todoagent-icon.png" alt="" /><span>TodoAgent</span></a>
        <p>Tasks, terminals, and agents. Together.</p>
        <div className="footer-links"><a href={githubUrl} target="_blank" rel="noreferrer">GitHub</a><a href={`${githubUrl}/blob/master/README.md`} target="_blank" rel="noreferrer">Documentation</a><a href={`${githubUrl}/issues`} target="_blank" rel="noreferrer">Issues</a></div>
        <div className="footer-legal">
          <span>© 2026 TodoAgent.</span>
          <span>Source available in a public repository. Product names are trademarks of their respective owners.</span>
        </div>
      </footer>
    </main>
  );
}
