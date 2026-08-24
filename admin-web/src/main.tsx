import React, { FormEvent, useCallback, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

type Summary = {
  accounts: number;
  activeDevices: number;
  channels: number;
  pendingEmail: number;
  pendingRecoveries: number;
};

type Member = {
  aci: string;
  email: string;
  isAdmin: boolean;
  activeDevices: number;
};

type Invitation = {
  invitationCode: string;
  expiresAt: string;
};

type Channel = {
  channelId: string;
  displayName: string;
  kind: string;
  membershipEpoch: number;
  retentionDays: number;
  activeMembers: number;
};

type Recovery = {
  requestId: string;
  email: string;
  deviceName: string;
  status: string;
  expiresAt: string;
  createdAt: string;
};

class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

async function api<T>(path: string, token: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...init?.headers,
    },
  });
  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as { message?: string } | null;
    throw new ApiError(response.status, body?.message ?? "The request failed.");
  }
  return (await response.json()) as T;
}

function App() {
  const [token, setToken] = useState(() => sessionStorage.getItem("ptt-admin-token") ?? "");
  const [summary, setSummary] = useState<Summary | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [channels, setChannels] = useState<Channel[]>([]);
  const [recoveries, setRecoveries] = useState<Recovery[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const load = useCallback(async () => {
    if (!token) return;
    setLoading(true);
    setError("");
    try {
      const [nextSummary, nextMembers, nextChannels, nextRecoveries] = await Promise.all([
        api<Summary>("/v1/admin/summary", token),
        api<Member[]>("/v1/admin/members", token),
        api<Channel[]>("/v1/admin/channels", token),
        api<Recovery[]>("/v1/admin/recoveries", token),
      ]);
      sessionStorage.setItem("ptt-admin-token", token);
      setSummary(nextSummary);
      setMembers(nextMembers);
      setChannels(nextChannels);
      setRecoveries(nextRecoveries);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to load this instance.");
      if (caught instanceof ApiError && caught.status === 401) {
        sessionStorage.removeItem("ptt-admin-token");
      }
    } finally {
      setLoading(false);
    }
  }, [token]);

  useEffect(() => {
    void load();
  }, []); // An existing session token is loaded exactly once at startup.

  function signOut() {
    sessionStorage.removeItem("ptt-admin-token");
    setToken("");
    setSummary(null);
    setMembers([]);
    setChannels([]);
    setRecoveries([]);
  }

  if (!summary) {
    return (
      <main className="login-shell">
        <form
          className="panel login-panel"
          onSubmit={(event) => {
            event.preventDefault();
            void load();
          }}
        >
          <p className="eyebrow">PTT Talk</p>
          <h1>Instance administration</h1>
          <p>Use the access token from an enrolled administrator device.</p>
          <label>
            Administrator token
            <input
              autoComplete="off"
              onChange={(event) => setToken(event.target.value.trim())}
              placeholder="Paste access token"
              type="password"
              value={token}
            />
          </label>
          {error && <p className="error" role="alert">{error}</p>}
          <button disabled={!token || loading} type="submit">
            {loading ? "Connecting…" : "Open console"}
          </button>
        </form>
      </main>
    );
  }

  return (
    <main className="app-shell">
      <header>
        <div>
          <p className="eyebrow">Private team instance</p>
          <h1>PTT Talk Admin</h1>
        </div>
        <div className="header-actions">
          <button className="secondary" onClick={() => void load()}>Refresh</button>
          <button className="secondary" onClick={signOut}>Sign out</button>
        </div>
      </header>

      {error && <p className="error" role="alert">{error}</p>}

      <section className="metrics" aria-label="Instance status">
        <Metric label="Members" value={summary.accounts} />
        <Metric label="Active devices" value={summary.activeDevices} />
        <Metric label="Channels" value={summary.channels} />
        <Metric label="Email queued" value={summary.pendingEmail} />
        <Metric label="Recovery approvals" value={summary.pendingRecoveries} />
      </section>

      <RecoveryPanel
        recoveries={recoveries}
        token={token}
        onChanged={() => void load()}
        onError={setError}
      />

      <InvitePanel
        token={token}
        onError={setError}
        onInvited={() => void load()}
      />

      <ChannelPanel
        channels={channels}
        members={members}
        token={token}
        onChanged={() => void load()}
        onError={setError}
      />

      <section className="panel">
        <div className="section-heading">
          <div>
            <p className="eyebrow">Directory</p>
            <h2>Members and devices</h2>
          </div>
          <span>{members.length} accounts</span>
        </div>
        <div className="table-wrap">
          <table>
            <thead><tr><th>Email</th><th>Role</th><th>Devices</th></tr></thead>
            <tbody>
              {members.map((member) => (
                <tr key={member.aci}>
                  <td>{member.email}</td>
                  <td>{member.isAdmin ? "Administrator" : "Member"}</td>
                  <td>{member.activeDevices} / 2</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}

function RecoveryPanel({
  recoveries,
  token,
  onChanged,
  onError,
}: {
  recoveries: Recovery[];
  token: string;
  onChanged: () => void;
  onError: (message: string) => void;
}) {
  const [working, setWorking] = useState("");

  async function decide(requestId: string, approve: boolean) {
    setWorking(requestId);
    onError("");
    try {
      await api<{ accepted: boolean }>("/v1/admin/recoveries/decision", token, {
        method: "POST",
        body: JSON.stringify({ requestId, approve }),
      });
      onChanged();
    } catch (caught) {
      onError(caught instanceof Error ? caught.message : "Unable to decide recovery.");
    } finally {
      setWorking("");
    }
  }

  return (
    <section className="panel">
      <div className="section-heading">
        <div><p className="eyebrow">Account security</p><h2>Recovery approvals</h2></div>
        <span>{recoveries.length} pending</span>
      </div>
      {recoveries.length === 0 && <p className="empty-state">No recovery requests need review.</p>}
      <div className="recovery-list">
        {recoveries.map((recovery) => (
          <article className="recovery-row" key={recovery.requestId}>
            <div>
              <strong>{recovery.email}</strong>
              <span>{recovery.deviceName} · expires {new Date(recovery.expiresAt).toLocaleString()}</span>
            </div>
            <div className="row-actions">
              <button
                className="secondary"
                disabled={working === recovery.requestId}
                onClick={() => void decide(recovery.requestId, false)}
              >Deny</button>
              <button
                disabled={working === recovery.requestId}
                onClick={() => void decide(recovery.requestId, true)}
              >Approve and revoke old devices</button>
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}

function ChannelPanel({
  channels,
  members,
  token,
  onChanged,
  onError,
}: {
  channels: Channel[];
  members: Member[];
  token: string;
  onChanged: () => void;
  onError: (message: string) => void;
}) {
  const [displayName, setDisplayName] = useState("");
  const [kind, setKind] = useState("team");
  const [retentionDays, setRetentionDays] = useState(30);
  const [selected, setSelected] = useState<string[]>([]);
  const [working, setWorking] = useState(false);

  async function create(event: FormEvent) {
    event.preventDefault();
    setWorking(true);
    onError("");
    try {
      await api<Channel>("/v1/admin/channels", token, {
        method: "POST",
        body: JSON.stringify({
          displayName,
          kind,
          retentionDays,
          members: selected.map((aci) => ({ aci, role: "talk" })),
        }),
      });
      setDisplayName("");
      setSelected([]);
      onChanged();
    } catch (caught) {
      onError(caught instanceof Error ? caught.message : "Unable to create channel.");
    } finally {
      setWorking(false);
    }
  }

  return (
    <section className="panel channel-panel">
      <div className="section-heading">
        <div><p className="eyebrow">Talk groups</p><h2>Channels</h2></div>
        <span>{channels.length} configured</span>
      </div>
      <div className="channel-grid">
        <div className="channel-list">
          {channels.length === 0 && <p className="empty-state">No channels yet.</p>}
          {channels.map((channel) => (
            <article className="channel-row" key={channel.channelId}>
              <div><strong>{channel.displayName}</strong><span>{channel.kind}</span></div>
              <div><strong>{channel.activeMembers}</strong><span>members</span></div>
              <div><strong>{channel.retentionDays}d</strong><span>retention</span></div>
              <div><strong>v{channel.membershipEpoch}</strong><span>key epoch</span></div>
            </article>
          ))}
        </div>
        <form className="channel-form" onSubmit={create}>
          <h3>Create channel</h3>
          <label>Name<input maxLength={80} onChange={(event) => setDisplayName(event.target.value)} value={displayName} /></label>
          <div className="compact-fields">
            <label>Type<select onChange={(event) => setKind(event.target.value)} value={kind}><option value="team">Team</option><option value="duty">Duty</option><option value="adhoc">Ad hoc</option></select></label>
            <label>Retention (days)<input max={365} min={1} onChange={(event) => setRetentionDays(Number(event.target.value))} type="number" value={retentionDays} /></label>
          </div>
          <fieldset>
            <legend>Initial members</legend>
            {members.map((member) => (
              <label className="check-row" key={member.aci}>
                <input
                  checked={selected.includes(member.aci)}
                  onChange={(event) => setSelected(event.target.checked ? [...selected, member.aci] : selected.filter((aci) => aci !== member.aci))}
                  type="checkbox"
                />
                <span>{member.email}</span>
              </label>
            ))}
          </fieldset>
          <button disabled={working || !displayName.trim() || selected.length === 0} type="submit">{working ? "Creating…" : "Create channel"}</button>
        </form>
      </div>
    </section>
  );
}

function Metric({ label, value }: { label: string; value: number }) {
  return <article className="metric"><strong>{value}</strong><span>{label}</span></article>;
}

function InvitePanel({
  token,
  onError,
  onInvited,
}: {
  token: string;
  onError: (message: string) => void;
  onInvited: () => void;
}) {
  const [email, setEmail] = useState("");
  const [invitation, setInvitation] = useState<Invitation | null>(null);
  const [working, setWorking] = useState(false);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setWorking(true);
    onError("");
    try {
      const created = await api<Invitation>("/v1/admin/invitations", token, {
        method: "POST",
        body: JSON.stringify({ email }),
      });
      setInvitation(created);
      setEmail("");
      onInvited();
    } catch (caught) {
      onError(caught instanceof Error ? caught.message : "Unable to create invitation.");
    } finally {
      setWorking(false);
    }
  }

  return (
    <section className="panel invite-panel">
      <div>
        <p className="eyebrow">Enrollment</p>
        <h2>Invite a member</h2>
        <p>Invitation codes expire in seven days and are bound to one email address.</p>
      </div>
      <form onSubmit={submit}>
        <label>
          Email address
          <input
            autoComplete="email"
            onChange={(event) => setEmail(event.target.value)}
            placeholder="teammate@example.com"
            type="email"
            value={email}
          />
        </label>
        <button disabled={!email || working} type="submit">
          {working ? "Creating…" : "Create invitation"}
        </button>
      </form>
      {invitation && (
        <div className="invitation-result" role="status">
          <strong>Invitation created</strong>
          <code>{invitation.invitationCode}</code>
          <span>Expires {new Date(invitation.expiresAt).toLocaleString()}</span>
        </div>
      )}
    </section>
  );
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode><App /></React.StrictMode>,
);
