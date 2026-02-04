# Changelog:

In order to help the product-team to compose better changelogs for our customers, please take your time and try to compose a changelog item. Try to describe your change from a customer perspective. Thanks!

- [ ] Improved by ...
- [ ] [internal] Improved by ...
- [ ] Fixed a bug where...
- [ ] [internal] Fixed a bug where ...
- [ ] Fixed security vulnerabilities in ...

# Success criteria

Please describe what should be possible after this change. List all individual items on a separate line.

- A
- B
- C

# How to test

Please describe the individual steps on how a peer can test your change.

1. A
2. B
3. C

# Security

- [ ] Possible injection vector
- [ ] Authentication/Access controls touched
- [ ] Sensitive Data could be exposed
- [ ] XSS
- [ ] Logging/Monitoring touched
- [ ] Exchanges data with external systems
- [ ] No security implications

# Additional considerations

- [ ] This PR impacts NLU
- [ ] This PR might have performance implications
- [ ] This PR changes an existing data model (and might affect existing legacy data)
  - Examples: adding, renaming, removing a field or changing the format or constraints of a field
- [ ] This PR might affect indexing
  - Examples: adding a new param for model query from DB without creating a new index for this model
