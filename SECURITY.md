# Security Policy

winCode is pre-alpha and has no supported releases yet.

## Reporting a vulnerability

Please do not open a public issue. The preferred channel is GitHub's private vulnerability reporting: go to the **Security** tab of this repository and choose **Report a vulnerability**. If that is unavailable, email bensefiayazid@gmail.com.

Include what you found, how to reproduce it, and the affected version or commit. We aim to acknowledge reports within 7 days.

## Scope

Of particular interest: handling of Apple credentials (App Store Connect API keys, certificates, provisioning profiles, session tokens), code signing, and anything that could leak or mis-sign user secrets.

## Never post secrets

If you accidentally commit or paste a `.p8`, `.p12`, certificate, or token anywhere in this project, revoke it with Apple immediately, then tell us.
