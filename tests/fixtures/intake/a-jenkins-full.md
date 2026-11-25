## What you want to build
Jenkins jobs — trigger a Jenkins build from DuploCloud and track its outcome.

## Inputs (what someone fills in when adding one)
- job name (required)
- branch (default: main)
- build parameters (optional, key-value)

## What should happen (after someone saves one)
Call Jenkins to start the build, poll until it finishes, capture the build number and result.

## Result to show
- build number
- status (SUCCESS / FAILED)
- duration
- link to the console log
