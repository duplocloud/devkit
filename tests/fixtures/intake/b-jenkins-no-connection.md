## What you want to build
Jenkins jobs — trigger a Jenkins build on our Jenkins server and track its outcome.

## Inputs (what someone fills in when adding one)
- job name (required)
- branch (default: main)

## What should happen (after someone saves one)
Call our Jenkins server to start the build and wait for it to finish.

## Result to show
- build number
- status
- link to the console log
