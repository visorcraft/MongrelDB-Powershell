# Security

This document describes the security properties of the MongrelDB PowerShell
client and how to report vulnerabilities.

## Overview

The MongrelDB PowerShell client is a module that talks to `mongreldb-server`
over HTTP using the built-in `Invoke-WebRequest` cmdlet. The client itself
holds no encryption keys and stores no data at rest; it is a thin
request/response layer over the daemon.

## Client security properties

- The client communicates with `mongreldb-server` over plain HTTP. The daemon
  binds to `127.0.0.1` by default - traffic stays on the loopback interface.
  For remote or multi-tenant deployments, terminate TLS in a reverse proxy
  (nginx, Caddy) in front of the daemon.
- The client supports Bearer token and HTTP Basic auth, matching the daemon's
  `--auth-token` and `--auth-users` modes. Credentials are sent only in the
  `Authorization` header and are never logged by the client.
- Auth credentials (token, username, password) are validated to reject CR/LF
  (carriage return / line feed) before use. Because these are placed verbatim
  into the Authorization header, an embedded newline would allow HTTP header
  injection (request splitting); the module refuses to construct a client with
  such a credential.
- `Invoke-WebRequest` is configured with `MaximumRedirection = 0` so an
  Authorization header cannot follow a redirect to an attacker-controlled host.
- The native condition API and query builder accept typed parameters (column
  IDs, typed values) - no string interpolation, no SQL injection surface.
  User-supplied values are serialized as typed JSON, not concatenated into
  queries.
- **WARNING - raw SQL:** The `Invoke-MongrelDBSql` cmdlet sends a raw SQL string
  to the server. It does NOT parameterize or sanitize input, and the client
  never interprets SQL locally. Never interpolate untrusted user input into SQL
  statements - use parameterized queries where the server supports them, or
  validate/escape input yourself. (The native condition API and query builder
  remain type-safe and are not affected.)
- Idempotency keys are caller-supplied opaque strings; the client does not
  derive or store them.
- Response bodies are capped at 256 MB so a runaway query or a misbehaving
  daemon cannot exhaust memory.

## Daemon security (mongreldb-server)

The client is a consumer of `mongreldb-server`. The daemon's security posture:

- Binds to `127.0.0.1` only - not accessible from other machines.
- **No authentication by default** - any local process can query, write, or
  delete data. Enable `--auth-token` or `--auth-users` for any shared host.
- No TLS - traffic is plaintext on the loopback interface.
- No rate limiting or request size caps.

For remote access or multi-tenant environments, place a reverse proxy (nginx,
Caddy) in front with TLS termination and authentication. Do not expose the
daemon directly to a network.

## Input validation

- The query builder produces typed JSON requests. Invalid column IDs, value
  encodings, and numeric ranges are rejected before any request is sent.
- Server and network errors are mapped to the typed error category hierarchy
  (`Auth`, `NotFound`, `Conflict`, `Query`, `Network`), not leaked as generic
  failures.

## Dependency security

The MongrelDB PowerShell client has no external module dependencies. It uses
only built-in cmdlets (`Invoke-WebRequest`, `ConvertTo-Json`, `ConvertFrom-Json`)
that ship with PowerShell. Keep your PowerShell installation patched. Report
any client-side vulnerabilities through the private vulnerability reporting
flow below.

## Reporting a vulnerability

**Do not file a public GitHub issue, discussion, or pull request for security
problems.** Report privately through **GitHub's private vulnerability
reporting**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with the details below.

Please include as much as you can:

- a description of the issue and its impact,
- step-by-step reproduction steps,
- the MongrelDB PowerShell client version, PowerShell edition and version, and OS,
- the `mongreldb-server` version if relevant,
- the relevant configuration, error output, or a proof-of-concept,
- a suggested fix or mitigation, if you have one.

### What to expect

- **Acknowledgement** of your report within a few days.
- An initial assessment and, where confirmed, a remediation plan.
- Progress updates through the private advisory thread until the issue is
  resolved.
- Credit for your responsible disclosure in the advisory, unless you prefer to
  remain anonymous.

We ask that you give us a reasonable opportunity to ship a fix before any
public disclosure.
