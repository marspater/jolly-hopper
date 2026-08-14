# Security Policy

## Supported Versions

Siphon is actively maintained on the latest stable release. Security fixes are generally provided for the latest major version.

| Version                | Supported      |
| ---------------------- | -------------- |
| Latest stable release  | ✅              |
| Previous major release | ⚠️ Best effort |
| Older releases         | ❌              |

Because this is a downloader application, security issues involving downloaded content, URL handling, browser extensions, local file access, or command execution are treated seriously. Humanity has already invented enough ways to accidentally execute malware.

## Reporting a Vulnerability

Please **do not open a public GitHub issue** for suspected security vulnerabilities.

Report vulnerabilities privately through GitHub's **Security Advisories** feature:

**https://github.com/jolly-hopper/Siphon/security/advisories/new**

When reporting a vulnerability, please include:

* A clear description of the vulnerability.
* The affected Siphon version.
* Steps to reproduce the issue.
* The expected and actual behavior.
* Any proof-of-concept, logs, screenshots, or example URLs that help reproduce the issue.
* Your assessment of the potential impact, if known.

Please avoid including sensitive information or malicious payloads unless they are necessary to reproduce the vulnerability.

## Response Process

Security reports will be reviewed as soon as reasonably possible.

When a report is received, the maintainers will:

1. Confirm whether the reported issue is reproducible.
2. Assess its severity and potential impact.
3. Develop and test a fix where appropriate.
4. Release a security update when necessary.
5. Credit the reporter, unless they prefer to remain anonymous.

Response times may vary depending on the severity and complexity of the issue.

## Scope

Security reports are especially relevant to vulnerabilities involving:

* Arbitrary code execution.
* Command or argument injection.
* Malicious URL handling.
* Path traversal or arbitrary file writes.
* Unsafe handling of downloaded files.
* Credential, cookie, or token exposure.
* Browser extension communication.
* Local privilege escalation.
* Remote code execution.
* Authentication or authorization bypasses.
* Dependency vulnerabilities that materially affect Siphon.

Issues that only affect the behavior or availability of third-party websites, external download providers, or content being downloaded are generally outside the project's security scope unless Siphon itself introduces the vulnerability.

## Out of Scope

The following are generally not considered security vulnerabilities:

* Bugs that do not have a meaningful security impact.
* Vulnerabilities exclusively affecting unsupported or obsolete versions.
* Social engineering attacks against users or maintainers.
* Issues caused solely by compromised third-party websites.
* Reports requiring an already-compromised local machine, unless Siphon provides a meaningful escalation path.
* Denial-of-service against third-party services caused by normal application usage.

## Security Updates

Security fixes will be released through the project's normal GitHub release process. Where appropriate, affected versions and the nature of the vulnerability will be documented in the corresponding release notes or GitHub Security Advisory.

## Responsible Disclosure

Please allow reasonable time for investigation and remediation before publicly disclosing a vulnerability.

We appreciate responsible security research and will make a reasonable effort to work with reporters toward coordinated disclosure.
