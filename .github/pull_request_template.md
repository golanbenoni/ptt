## What changed

Describe the user or operator outcome and the smallest important implementation details.

## Related issue or discussion

Link the design discussion or issue when one exists.

## Security and privacy impact

Describe changes to encryption, identity, authorization, metadata, retention,
logging, transport, permissions, dependencies, or deployment boundaries. Write
`None` only after reviewing each category.

## Verification

List the exact automated and manual checks performed, including platforms,
devices, network conditions, and negative tests where relevant.

## Checklist

- [ ] The change is narrowly scoped and documented.
- [ ] Tests cover success, failure, and unauthorized behavior where applicable.
- [ ] No credentials, private communications, personal data, push tokens, raw identifiers, or key material are included.
- [ ] Protocol changes preserve compatibility or update every implementation and golden vector together.
- [ ] Voice, chat, and attachment failures remain fail-closed with no plaintext fallback.
- [ ] UI changes were checked for accessibility, large text, light/dark appearance, and relevant device sizes.
- [ ] Deployment changes include upgrade, rollback, backup, and restore impact.
