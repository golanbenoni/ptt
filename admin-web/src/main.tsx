import React, { FormEvent, useCallback, useEffect, useRef, useState } from "react";
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
  displayName: string;
  accountKind: "member" | "guest";
  guestExpiresAt: string | null;
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
  topic: string;
  isAnnouncement: boolean;
  archivedAt: string | null;
  membershipEpoch: number;
  retentionDays: number;
  activeMembers: number;
};

type ChannelTemplate = {
  templateId: string;
  displayName: string;
  channelKind: string;
  topic: string;
  retentionDays: number;
  defaultRole: string;
  isAnnouncement: boolean;
};

type UserGroup = { groupId: string; displayName: string; handle: string; memberCount: number };
type Integration = {
  integrationId: string;
  aci: string;
  channelId: string;
  displayName: string;
  capabilities: string[];
  expiresAt: string | null;
  revokedAt: string | null;
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
  apnsProductionConfigured: boolean;
  apnsSandboxConfigured: boolean;
  apnsCredentialsSeparated: boolean;
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

async function publicApi<T>(path: string, init: RequestInit): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: { "Content-Type": "application/json", ...init.headers },
  });
  if (!response.ok) {
    const responseBody = (await response.json().catch(() => null)) as { message?: string } | null;
    throw new ApiError(response.status, responseBody?.message ?? "The request failed.");
  }
  return (await response.json()) as T;
}

function takeHandoffFromFragment(): string {
  const code = new URLSearchParams(window.location.hash.slice(1)).get("handoff")?.trim() ?? "";
  if (window.location.hash) window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}`);
  return code;
}

function App() {
  // The browser receives only a short-lived admin session. It stays in memory,
  // and the one-time handoff is erased from the address bar before redemption.
  const [token, setToken] = useState("");
  const [handoffCode, setHandoffCode] = useState(takeHandoffFromFragment);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [channels, setChannels] = useState<Channel[]>([]);
  const [recoveries, setRecoveries] = useState<Recovery[]>([]);
  const [devices, setDevices] = useState<Device[]>([]);
  const [audit, setAudit] = useState<AuditEvent[]>([]);
  const [operations, setOperations] = useState<Operations | null>(null);
  const [templates, setTemplates] = useState<ChannelTemplate[]>([]);
  const [groups, setGroups] = useState<UserGroup[]>([]);
  const [integrations, setIntegrations] = useState<Integration[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const initialHandoffCode = useRef(handoffCode);
  const autoHandoffStarted = useRef(false);

  const loadWithToken = useCallback(async (candidateToken: string) => {
    setLoading(true);
    setError("");
    try {
      const [nextSummary, nextMembers, nextChannels, nextRecoveries, nextDevices, nextAudit, nextOperations, nextTemplates, nextGroups, nextIntegrations] = await Promise.all([
        api<Summary>("/v1/admin/summary", candidateToken),
        api<Member[]>("/v1/admin/members", candidateToken),
        api<Channel[]>("/v1/admin/channels", candidateToken),
        api<Recovery[]>("/v1/admin/recoveries", candidateToken),
        api<Device[]>("/v1/admin/devices", candidateToken),
        api<AuditEvent[]>("/v1/admin/audit?limit=100", candidateToken),
        api<Operations>("/v1/admin/operations", candidateToken),
        api<ChannelTemplate[]>("/v1/admin/channel-templates", candidateToken),
        api<UserGroup[]>("/v1/admin/user-groups", candidateToken),
        api<Integration[]>("/v1/admin/integrations", candidateToken),
      ]);
      setToken(candidateToken);
      setSummary(nextSummary);
      setMembers(nextMembers);
      setChannels(nextChannels);
      setRecoveries(nextRecoveries);
      setDevices(nextDevices);
      setAudit(nextAudit);
      setOperations(nextOperations);
      setTemplates(nextTemplates);
      setGroups(nextGroups);
      setIntegrations(nextIntegrations);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to load this instance.");
      if (caught instanceof ApiError && caught.status === 401) {
        setToken("");
      }
    } finally {
      setLoading(false);
    }
  }, []);

  const load = useCallback(async () => {
    if (token) await loadWithToken(token);
  }, [loadWithToken, token]);

  const consumeHandoff = useCallback(async (code: string) => {
    if (!code.trim()) return;
    setLoading(true);
    setError("");
    try {
      const session = await publicApi<{ sessionToken: string; expiresAt: string }>(
        "/v1/admin/session/consume",
        { method: "POST", body: JSON.stringify({ handoffCode: code.trim() }) },
      );
      setHandoffCode("");
      await loadWithToken(session.sessionToken);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to approve this browser.");
      setLoading(false);
    }
  }, [loadWithToken]);

  useEffect(() => {
    if (!initialHandoffCode.current || autoHandoffStarted.current) return;
    autoHandoffStarted.current = true;
    void consumeHandoff(initialHandoffCode.current);
  }, [consumeHandoff]);

  async function signOut() {
    try {
      if (token) await api<{ accepted: boolean }>("/v1/admin/session/revoke", token, { method: "POST", body: "{}" });
    } finally {
      setToken("");
      setSummary(null);
      setMembers([]);
      setChannels([]);
      setRecoveries([]);
      setDevices([]);
      setAudit([]);
      setOperations(null);
      setTemplates([]);
      setGroups([]);
      setIntegrations([]);
    }
  }

  if (!summary) {
    return (
      <main className="login-shell">
        <form className="panel login-panel" onSubmit={(event) => { event.preventDefault(); void consumeHandoff(handoffCode); }}>
          <p className="eyebrow">PTT Talk</p>
          <h1>{loading ? "Approving this browser…" : "Instance administration"}</h1>
          <p>On an enrolled administrator device, open PTT Talk → Settings → Admin console. The app creates a single-use approval that expires in two minutes.</p>
          <label>
            One-time approval code
            <input
              autoComplete="off"
              onChange={(event) => setHandoffCode(event.target.value)}
              placeholder="Paste code if this browser did not open automatically"
              spellCheck={false}
              type="text"
              value={handoffCode}
            />
          </label>
          {error && <p className="error" role="alert">{error}</p>}
          <button disabled={!handoffCode.trim() || loading} type="submit">
            {loading ? "Connecting…" : "Approve browser"}
          </button>
          <p className="login-note">No permanent device credential is copied into this browser. Admin access expires automatically after 15 minutes.</p>
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
          <button className="secondary" onClick={() => void signOut()}>Sign out</button>
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
        templates={templates}
        token={token}
        onChanged={() => void load()}
        onError={setError}
      />

      <CollaborationControls
        channels={channels}
        groups={groups}
        integrations={integrations}
        members={members}
        onChanged={() => void load()}
        onError={setError}
        templates={templates}
        token={token}
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
                  <td><strong>{member.displayName}</strong><br /><span>{member.email}</span></td>
                  <td>{member.isAdmin ? "Administrator" : member.accountKind === "guest" ? "Guest" : "Member"}</td>
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
  templates,
  token,
  onChanged,
  onError,
}: {
  channels: Channel[];
  members: Member[];
  templates: ChannelTemplate[];
  token: string;
  onChanged: () => void;
  onError: (message: string) => void;
}) {
  const [displayName, setDisplayName] = useState("");
  const [kind, setKind] = useState("team");
  const [retentionDays, setRetentionDays] = useState(30);
  const [topic, setTopic] = useState("");
  const [isAnnouncement, setIsAnnouncement] = useState(false);
  const [selected, setSelected] = useState<string[]>([]);
  const [working, setWorking] = useState(false);
  const [templateId, setTemplateId] = useState("");

  function applyTemplate(value: string) {
    setTemplateId(value);
    const template = templates.find((item) => item.templateId === value);
    if (!template) return;
    setDisplayName(template.displayName);
    setKind(template.channelKind);
    setRetentionDays(template.retentionDays);
    setTopic(template.topic);
    setIsAnnouncement(template.isAnnouncement);
  }

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
          topic,
          isAnnouncement,
          members: selected.map((aci) => ({ aci, role: "talk" })),
        }),
      });
      setDisplayName("");
      setSelected([]);
      setTopic("");
      setIsAnnouncement(false);
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
          {templates.length > 0 && <label>Start from template<select onChange={(event) => applyTemplate(event.target.value)} value={templateId}><option value="">Blank channel</option>{templates.map((template) => <option key={template.templateId} value={template.templateId}>{template.displayName}</option>)}</select></label>}
          <label>Name<input maxLength={80} onChange={(event) => setDisplayName(event.target.value)} value={displayName} /></label>
          <label>Purpose or topic<input maxLength={280} onChange={(event) => setTopic(event.target.value)} placeholder="What belongs in this channel?" value={topic} /></label>
          <div className="compact-fields">
            <label>Type<select onChange={(event) => setKind(event.target.value)} value={kind}><option value="team">Team</option><option value="duty">Duty</option><option value="adhoc">Ad hoc</option><option value="direct">Private 1:1</option></select></label>
            <label>Retention (days)<input max={365} min={1} onChange={(event) => setRetentionDays(Number(event.target.value))} type="number" value={retentionDays} /></label>
          </div>
          <label className="check-row"><input checked={isAnnouncement} onChange={(event) => setIsAnnouncement(event.target.checked)} type="checkbox" /><span>Announcement channel (Dispatch and Barge roles post)</span></label>
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
  const [topic, setTopic] = useState(channel.topic);
  const [isAnnouncement, setIsAnnouncement] = useState(channel.isAnnouncement);
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
        body: JSON.stringify({ channelId: channel.channelId, displayName, retentionDays, topic, isAnnouncement }),
      });
      onChanged();
    } catch (caught) {
      onError(caught instanceof Error ? caught.message : "Unable to update channel.");
    } finally {
      setWorking(false);
    }
  }

  const changed = displayName.trim() !== channel.displayName || retentionDays !== channel.retentionDays ||
    topic.trim() !== channel.topic || isAnnouncement !== channel.isAnnouncement;
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
      <div className="compact-fields channel-metadata">
        <label>Topic<input maxLength={280} onChange={(event) => setTopic(event.target.value)} value={topic} /></label>
        <label className="check-row"><input checked={isAnnouncement} onChange={(event) => setIsAnnouncement(event.target.checked)} type="checkbox" /><span>Announcements only</span></label>
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

function CollaborationControls({ channels, groups, integrations, members, onChanged, onError, templates, token }: {
  channels: Channel[];
  groups: UserGroup[];
  integrations: Integration[];
  members: Member[];
  onChanged: () => void;
  onError: (message: string) => void;
  templates: ChannelTemplate[];
  token: string;
}) {
  const [templateName, setTemplateName] = useState("");
  const [templateTopic, setTemplateTopic] = useState("");
  const [groupName, setGroupName] = useState("");
  const [groupHandle, setGroupHandle] = useState("");
  const [groupMembers, setGroupMembers] = useState<string[]>([]);
  const [groupChannel, setGroupChannel] = useState("");
  const [groupRole, setGroupRole] = useState("talk");
  const [integrationName, setIntegrationName] = useState("");
  const [integrationChannel, setIntegrationChannel] = useState("");
  const [identityKey, setIdentityKey] = useState("");
  const [issuedIntegration, setIssuedIntegration] = useState("");
  const [working, setWorking] = useState(false);

  async function run(action: () => Promise<unknown>) {
    setWorking(true); onError("");
    try { await action(); onChanged(); } catch (caught) {
      onError(caught instanceof Error ? caught.message : "Unable to update collaboration controls.");
    } finally { setWorking(false); }
  }

  return (
    <section className="panel">
      <div className="section-heading">
        <div><p className="eyebrow">Workspace controls</p><h2>Teams, templates, and secure automation</h2></div>
        <span>Single-tenant and channel scoped</span>
      </div>
      <div className="channel-grid collaboration-grid">
        <div>
          <h3>Member access</h3>
          <p className="empty-state">Guests expire automatically. An active administrator cannot remove their own access.</p>
          {members.map((member) => <MemberConfigRow key={member.aci} member={member} onChanged={onChanged} onError={onError} token={token} />)}
        </div>
        <form className="channel-form" onSubmit={(event) => {
          event.preventDefault();
          void run(async () => {
            await api("/v1/admin/channel-templates", token, { method: "POST", body: JSON.stringify({
              displayName: templateName, channelKind: "team", topic: templateTopic, retentionDays: 30,
              defaultRole: "talk", isAnnouncement: false,
            }) });
            setTemplateName(""); setTemplateTopic("");
          });
        }}>
          <h3>Channel templates</h3>
          {templates.map((template) => <p className="compact-record" key={template.templateId}><strong>{template.displayName}</strong><span>{template.channelKind} · {template.retentionDays} days · {roleLabel(template.defaultRole)}</span></p>)}
          <label>Template name<input maxLength={80} onChange={(event) => setTemplateName(event.target.value)} value={templateName} /></label>
          <label>Default topic<input maxLength={280} onChange={(event) => setTemplateTopic(event.target.value)} value={templateTopic} /></label>
          <button disabled={working || !templateName.trim()} type="submit">Save template</button>
        </form>
        <form className="channel-form" onSubmit={(event) => {
          event.preventDefault();
          void run(async () => {
            await api("/v1/admin/user-groups", token, { method: "POST", body: JSON.stringify({
              displayName: groupName, handle: groupHandle, memberAcis: groupMembers,
            }) });
            setGroupName(""); setGroupHandle(""); setGroupMembers([]);
          });
        }}>
          <h3>User groups</h3>
          {groups.map((group) => <div className="compact-record" key={group.groupId}>
            <strong>@{group.handle}</strong><span>{group.displayName} · {group.memberCount} members</span>
            <button disabled={working || !groupChannel} onClick={() => void run(() => api("/v1/admin/user-groups/apply", token, {
              method: "POST", body: JSON.stringify({ groupId: group.groupId, channelId: groupChannel, role: groupRole }),
            }))} type="button">Add to channel</button>
          </div>)}
          <label>Target channel<select onChange={(event) => setGroupChannel(event.target.value)} value={groupChannel}><option value="">Choose…</option>{channels.filter((channel) => channel.kind !== "direct").map((channel) => <option key={channel.channelId} value={channel.channelId}>{channel.displayName}</option>)}</select></label>
          <label>Channel role<select onChange={(event) => setGroupRole(event.target.value)} value={groupRole}><option value="talk">Talk</option><option value="listen">Listen only</option><option value="dispatch">Dispatch</option></select></label>
          <label>Name<input maxLength={80} onChange={(event) => setGroupName(event.target.value)} value={groupName} /></label>
          <label>Handle<input maxLength={32} onChange={(event) => setGroupHandle(event.target.value.toLowerCase())} placeholder="dispatch_team" value={groupHandle} /></label>
          <fieldset><legend>Members</legend>{members.map((member) => <label className="check-row" key={member.aci}>
            <input checked={groupMembers.includes(member.aci)} onChange={(event) => setGroupMembers(event.target.checked ? [...groupMembers, member.aci] : groupMembers.filter((aci) => aci !== member.aci))} type="checkbox" />
            <span>{member.displayName}</span>
          </label>)}</fieldset>
          <button disabled={working || !groupName.trim() || !groupHandle.trim()} type="submit">Create group</button>
        </form>
        <form className="channel-form" onSubmit={(event) => {
          event.preventDefault();
          void run(async () => {
            const created = await api<{ token: string; aci: string; deviceId: number; mailboxId: string }>("/v1/admin/integrations", token, { method: "POST", body: JSON.stringify({
              channelId: integrationChannel, displayName: integrationName, identityKey,
              capabilities: ["post", "acknowledge"],
            }) });
            setIssuedIntegration(JSON.stringify({ aci: created.aci, deviceId: created.deviceId, mailboxId: created.mailboxId, accessToken: created.token }, null, 2));
            setIntegrationName(""); setIdentityKey("");
          });
        }}>
          <h3>Secure integrations</h3>
          <p className="empty-state">Automation encrypts payloads for enrolled devices. The service never receives message plaintext.</p>
          {integrations.map((integration) => <div className="compact-record" key={integration.integrationId}>
            <strong>{integration.displayName}{integration.revokedAt ? " · revoked" : ""}</strong>
            <span>{integration.capabilities.join(", ")}</span>
            {!integration.revokedAt && <button disabled={working} onClick={() => void run(() => api("/v1/admin/integrations/revoke", token, {
              method: "POST", body: JSON.stringify({ integrationId: integration.integrationId }),
            }))} type="button">Revoke</button>}
          </div>)}
          {issuedIntegration && <label>One-time device credentials<textarea readOnly rows={7} value={issuedIntegration} /></label>}
          <label>Name<input maxLength={80} onChange={(event) => setIntegrationName(event.target.value)} value={integrationName} /></label>
          <label>Channel<select onChange={(event) => setIntegrationChannel(event.target.value)} value={integrationChannel}><option value="">Choose…</option>{channels.map((channel) => <option key={channel.channelId} value={channel.channelId}>{channel.displayName}</option>)}</select></label>
          <label>Public identity key (base64url)<textarea onChange={(event) => setIdentityKey(event.target.value.trim())} rows={3} value={identityKey} /></label>
          <button disabled={working || !integrationName.trim() || !integrationChannel || !identityKey} type="submit">Enroll integration</button>
        </form>
      </div>
    </section>
  );
}

function MemberConfigRow({ member, onChanged, onError, token }: {
  member: Member; onChanged: () => void; onError: (message: string) => void; token: string;
}) {
  const [displayName, setDisplayName] = useState(member.displayName);
  const [accountKind, setAccountKind] = useState(member.accountKind);
  const [isAdmin, setIsAdmin] = useState(member.isAdmin);
  const [guestExpiresAt, setGuestExpiresAt] = useState(member.guestExpiresAt?.slice(0, 16) ?? "");
  const [working, setWorking] = useState(false);
  async function save() {
    setWorking(true); onError("");
    try {
      await api("/v1/admin/members/config", token, { method: "POST", body: JSON.stringify({
        aci: member.aci, displayName, accountKind, isAdmin,
        guestExpiresAt: accountKind === "guest" && guestExpiresAt ? new Date(guestExpiresAt).toISOString() : null,
      }) });
      onChanged();
    } catch (caught) { onError(caught instanceof Error ? caught.message : "Unable to update member."); }
    finally { setWorking(false); }
  }
  return <div className="membership-row member-config-row">
    <input aria-label="Display name" maxLength={80} onChange={(event) => setDisplayName(event.target.value)} value={displayName} />
    <select aria-label="Account type" onChange={(event) => setAccountKind(event.target.value as "member" | "guest")} value={accountKind}><option value="member">Member</option><option value="guest">Guest</option></select>
    {accountKind === "guest" && <input aria-label="Guest expiry" min={new Date().toISOString().slice(0, 16)} onChange={(event) => setGuestExpiresAt(event.target.value)} type="datetime-local" value={guestExpiresAt} />}
    <label className="check-row"><input checked={isAdmin} onChange={(event) => setIsAdmin(event.target.checked)} type="checkbox" /><span>Admin</span></label>
    <button disabled={working || !displayName.trim() || (accountKind === "guest" && !guestExpiresAt)} onClick={() => void save()} type="button">Save</button>
  </div>;
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
        FCM {operations.fcmConfigured ? "configured" : "not configured"} · APNs {operations.apnsConfigured ? "production + sandbox isolated" : "not release-ready"} · Backups {operations.backupConfigured ? operations.backupSchedule : "not configured"}
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
