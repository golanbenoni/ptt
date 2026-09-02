export async function notifyChannelMembershipChanged(
  env: Env,
  channelId: string,
  membershipEpoch: number,
): Promise<void> {
  await env.CHANNELS.getByName(channelId, { locationHint: "enam" })
    .membershipChanged(membershipEpoch);
}

export async function notifyChannelsMembershipChanged(
  env: Env,
  channelIds: readonly string[],
): Promise<void> {
  await Promise.all(channelIds.map(async (channelId) => {
    const channel = await env.DB.prepare(
      "SELECT membership_epoch AS membershipEpoch FROM channels WHERE channel_id=?",
    ).bind(channelId).first<{ membershipEpoch: number }>();
    if (channel) {
      await notifyChannelMembershipChanged(env, channelId, channel.membershipEpoch);
    }
  }));
}
