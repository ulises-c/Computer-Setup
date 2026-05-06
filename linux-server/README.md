# Useful Linux Server software

Tested on Ubuntu Server. Most packages should work on other Debian-based distros.

## Utilities

1. atvloadly | [GitHub](https://github.com/bitxeno/atvloadly)
   1. Self-hosted web app for sideloading IPA files onto Apple TV — a self-deployable alternative to AltStore/Sideloadly
   2. Deploy via Docker: `docker run -d --name atvloadly --restart=unless-stopped -p 8080:80 bitxeno/atvloadly`
