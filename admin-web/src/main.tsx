import React, { FormEvent, useCallback, useState } from "react";
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

type ChannelMember = {
  channelId: string;
  aci: string;
  email: string;
  role: string;
  joinedEpoch: number;
};

type Recovery = {
  requestId: string;
  email: string;
  deviceName: string;
  status: string;
  expiresAt: string;
  createdAt: string;
};

type Device = {
  aci: string;
  email: string;
  deviceId: number;
  displayName: string;
  status: string;
  linkedAt: string;
  revokedAt: string | null;
};

type AuditEvent = {
  eventId: number;
  action: string;
  subjectHash: string | null;
  detail: Record<string, unknown>;
  createdAt: string;
};

type Operations = {
  activeRelayLeases: number;
  pendingPush: number;
  failedPush: number;
  historyObjects: number;
  fcmConfigured: boolean;
  apnsConfigured: boolean;
  backupConfigured: boolean;
  backupSchedule: string;
  configurationFingerprint: string;
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
  // Keep the bearer credential in memory only. A refresh intentionally signs
  // the administrator out so injected or later-loaded scripts cannot recover it.
  const [token, setToken] = useState("");
  const [summary, setSummary] = useState<Summary | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [channels, setChannels] = useState<Channel[]>([]);
  const [recoveries, setRecoveries] = useState<Recovery[]>([]);
  const [devices, setDevices] = useState<Device[]>([]);
  const [audit, setAudit] = useState<AuditEvent[]>([]);
  const [operations, setOperations] = useState<Operations | null>(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const load = useCallback(async () => {
    if (!token) return;
    setLoading(true);
    setError("");
    try {
      const [nextSummary, nextMembers, nextChannels, nextRecoveries, nextDevices, nextAudit, nextOperations] = await Promise.all([
        api<Summary>("/v1/admin/summary", token),
        api<Member[]>("/v1/admin/members", token),
        api<Channel[]>("/v1/admin/channels", token),
        api<Recovery[]>("/v1/admin/recoveries", token),
        api<Device[]>("/v1/admin/devices", token),
        api<AuditEvent[]>("/v1/admin/audit?limit=100", token),
        api<Operations>("/v1/admin/operations", token),
      ]);
      setSummary(nextSummary);
      setMembers(nextMembers);
      setChannels(nextChannels);
      setRecoveries(nextRecoveries);
      setDevices(nextDevices);
      setAudit(nextAudit);
      setOperations(nextOperations);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to load this instance.");
      if (caught instanceof ApiError && caught.status === 401) {
        setToken("");
      }
    } finally {
      setLoading(false);
    }
  }, [token]);

  function signOut() {
    setToken("");
    setSummary(null);
    setMembers([]);
    setChannels([]);
    setRecoveries([]);
    setDevices([]);
    setAudit([]);
    setOperations(null);
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

      {operations && <OperationsPanel operations={operations} />}

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

      <DevicePanel devices={devices} token={token} onChanged={() => void load()} onError={setError} />

      <AuditPanel events={audit} />

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
            <ChannelConfigRow
              channel={channel}
              key={channel.channelId}
              members={members}
              token={token}
              onChanged={onChanged}
              onError={onError}
            />
          ))}
        </div>
        <form className="channel-form" onSubmit={create}>
          <h3>Create channel</h3>
          <label>Name<input maxLength={80} onChange={(event) => setDisplayName(event.target.value)} value={displayName} /></label>
          <div className="compact-fields">
            <label>Type<select onChange={(event) => setKind(event.target.value)} value={kind}><option value="team">Team</option><option value="duty">Duty</option><option value="adhoc">Ad hoc</option><option value="direct">Private 1:1</option></select></label>
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

function ChannelConfigRow({
  channel,
  members,
  token,
  onChanged,
  onError,
}: {
  channel: Channel;
  members: Member[];
  token: string;
  onChanged: () => void;
  onError: (message: string) => void;
}) {
  const [displayName, setDisplayName] = useState(channel.displayName);
  const [retentionDays, setRetentionDays] = useState(channel.retentionDays);
  const [working, setWorking] = useState(false);
  const [membershipOpen, setMembershipOpen] = useState(false);
  const [channelMembers, setChannelMembers] = useState<ChannelMember[]>([]);
  const [memberAci, setMemberAci] = useState("");
  const [memberRole, setMemberRole] = useState("talk");

  async function loadMembership() {
    setWorking(true);
    onError("");
    try {
      const rows = await api<ChannelMember[]>(
        `/v1/admin/channels/members?channelId=${encodeURIComponent(channel.channelId)}`,
        token,
      );
      setChannelMembers(rows);
      setMembershipOpen(true);
    } catch (caught) {
      onError(caught instanceof Error ? caught.message : "Unable to load channel membership.");
    } finally {
      setWorking(false);
    }
  }

  async function changeMembership(aci: string, role: string | null, remove: boolean) {
    setWorking(true);
    onError("");
    try {
      await api<{ accepted: boolean }>("/v1/admin/channels/membership", token, {
        method: "POST",
        body: JSON.stringify({ channelId: channel.channelId, aci, role, remove }),
      });
      const rows = await api<ChannelMember[]>(
        `/v1/admin/channels/members?channelId=${encodeURIComponent(channel.channelId)}`,
        token,
      );
      setChannelMembers(rows);
      setMemberAci("");
      onChanged();
    } catch (caught) {
      onError(caught instanceof Error ? caught.message : "Unable to update channel membership.");
    } finally {
      setWorking(false);
    }
  }

  async function save() {
    setWorking(true);
    onError("");
    try {
      await api<Channel>("/v1/admin/channels/config", token, {
        method: "POST",
        body: JSON.stringify({ channelId: channel.channelId, displayName, retentionDays }),
      });
      onChanged();
    } catch (caught) {
      onError(caught instanceof Error ? caught.message : "Unable to update channel.");
    } finally {
      setWorking(false);
    }
  }

  const changed = displayName.trim() !== channel.displayName || retentionDays !== channel.retentionDays;
  return (
    <article className="channel-card">
      <div className="channel-row">
        <label>Name<input maxLength={80} onChange={(event) => setDisplayName(event.target.value)} value={displayName} /></label>
        <div><strong>{channel.activeMembers}</strong><span>members · {channel.kind}</span></div>
        <label>Retention<input max={365} min={1} onChange={(event) => setRetentionDays(Number(event.target.value))} type="number" value={retentionDays} /></label>
        <div><strong>v{channel.membershipEpoch}</strong><span>key epoch</span></div>
        <button disabled={!changed || !displayName.trim() || retentionDays < 1 || retentionDays > 365 || working} onClick={() => void save()} type="button">
          {working ? "Saving…" : "Save"}
        </button>
        <button className="secondary" disabled={working} onClick={() => membershipOpen ? setMembershipOpen(false) : void loadMembership()} type="button">
          {membershipOpen ? "Close members" : "Manage members"}
        </button>
      </div>
      {membershipOpen && (
        <div className="membership-editor">
          {channelMembers.map((member) => (
            <div className="membership-row" key={member.aci}>
              <span>{member.email}</span>
              <select
                aria-label={`Role for ${member.email}`}
                disabled={working}
                onChange={(event) => void changeMembership(member.aci, event.target.value, false)}
                value={member.role}
              >
                {roleOptions.map((role) => <option key={role} value={role}>{roleLabel(role)}</option>)}
              </select>
              <button className="secondary" disabled={working} onClick={() => void changeMembership(member.aci, null, true)} type="button">Remove</button>
            </div>
          ))}
          <div className="membership-row">
            <select aria-label="Member to add" onChange={(event) => setMemberAci(event.target.value)} value={memberAci}>
              <option value="">Add a member…</option>
              {members.filter((member) => !channelMembers.some((current) => current.aci === member.aci)).map((member) => (
                <option key={member.aci} value={member.aci}>{member.email}</option>
              ))}
            </select>
            <select aria-label="New member role" onChange={(event) => setMemberRole(event.target.value)} value={memberRole}>
              {roleOptions.map((role) => <option key={role} value={role}>{roleLabel(role)}</option>)}
            </select>
            <button disabled={!memberAci || working} onClick={() => void changeMembership(memberAci, memberRole, false)} type="button">Add</button>
          </div>
          <p className="empty-state">Every change rotates the channel membership epoch; newly added devices receive future transmissions only.</p>
        </div>
      )}
    </article>
  );
}

const roleOptions = ["talk", "listen", "barge", "dispatch", "emergency-target"];
function roleLabel(role: string) {
  return role.split("-").map((word) => word[0].toUpperCase() + word.slice(1)).join(" ");
}

function OperationsPanel({ operations }: { operations: Operations }) {
  return (
    <section className="panel">
      <div className="section-heading">
        <div><p className="eyebrow">Operations</p><h2>Delivery and recovery posture</h2></div>
        <code>{operations.configurationFingerprint}</code>
      </div>
      <div className="metrics">
        <Metric label="Relay leases" value={operations.activeRelayLeases} />
        <Metric label="Push queued" value={operations.pendingPush} />
        <Metric label="Push retries" value={operations.failedPush} />
        <Metric label="History objects" value={operations.historyObjects} />
      </div>
      <p>
        FCM {operations.fcmConfigured ? "configured" : "not configured"} · APNs {operations.apnsConfigured ? "configured" : "not configured"} · Backups {operations.backupConfigured ? operations.backupSchedule : "not configured"}
      </p>
    </section>
  );
}

function DevicePanel({
  devices,
  token,
  onChanged,
  onError,
}: {
  devices: Device[];
  token: string;
  onChanged: () => void;
  onError: (message: string) => void;
}) {
  const [working, setWorking] = useState("");
  async function revoke(device: Device) {
    if (!window.confirm(`Revoke ${device.displayName} for ${device.email}? Channel keys will rotate immediately.`)) return;
    const id = `${device.aci}:${device.deviceId}`;
    setWorking(id);
    onError("");
    try {
      await api<{ accepted: boolean }>("/v1/admin/devices/revoke", token, {
        method: "POST",
        body: JSON.stringify({ aci: device.aci, deviceId: device.deviceId }),
      });
      onChanged();
    } catch (caught) {
      onError(caught instanceof Error ? caught.message : "Unable to revoke device.");
    } finally {
      setWorking("");
    }
  }
  return (
    <section className="panel">
      <div className="section-heading"><div><p className="eyebrow">Endpoint security</p><h2>Device revocation</h2></div><span>{devices.filter((device) => device.status === "active").length} active</span></div>
      <div className="table-wrap">
        <table>
          <thead><tr><th>Member</th><th>Device</th><th>Status</th><th>Linked</th><th /></tr></thead>
          <tbody>{devices.map((device) => {
            const id = `${device.aci}:${device.deviceId}`;
            return <tr key={id}><td>{device.email}</td><td>{device.displayName} · #{device.deviceId}</td><td>{device.status}</td><td>{new Date(device.linkedAt).toLocaleString()}</td><td>{device.status === "active" && <button className="secondary" disabled={working === id} onClick={() => void revoke(device)}>{working === id ? "Revoking…" : "Revoke"}</button>}</td></tr>;
          })}</tbody>
        </table>
      </div>
    </section>
  );
}

function AuditPanel({ events }: { events: AuditEvent[] }) {
  return (
    <section className="panel">
      <div className="section-heading"><div><p className="eyebrow">Audit</p><h2>Recent security events</h2></div><span>{events.length} shown</span></div>
      <div className="table-wrap">
        <table>
          <thead><tr><th>Time</th><th>Action</th><th>Subject fingerprint</th><th>Detail</th></tr></thead>
          <tbody>{events.map((event) => <tr key={event.eventId}><td>{new Date(event.createdAt).toLocaleString()}</td><td>{event.action}</td><td><code>{event.subjectHash?.slice(0, 16) ?? "—"}</code></td><td><code>{JSON.stringify(event.detail)}</code></td></tr>)}</tbody>
        </table>
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
  const [invitedEmail, setInvitedEmail] = useState("");
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
      setInvitedEmail(email);
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
        <p>PTT Talk emails a private, single-use enrollment link directly to the member.</p>
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
          {working ? "Sending…" : "Send invitation"}
        </button>
      </form>
      {invitation && (
        <div className="invitation-result" role="status">
          <strong>Invitation sent to {invitedEmail}</strong>
          <span>They can open the email on their phone and tap Join PTT Talk. No code copying is required.</span>
          <details>
            <summary>Need manual setup?</summary>
            <span>Give this one-time fallback code only to {invitedEmail}:</span>
            <code>{invitation.invitationCode}</code>
            <span>Expires {new Date(invitation.expiresAt).toLocaleString()}</span>
          </details>
        </div>
      )}
    </section>
  );
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode><App /></React.StrictMode>,
);
