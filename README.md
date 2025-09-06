#This series of script provides a 3 part process

PUT ALL RELEVANT FILES IN C:\workspace ON TARGET WORKSTATIONS
BUILD PPKG FILE FOR YOUR ENTRA MIGRATION AND DEPLOY TO ALL WORKSTATIONS IN C:\workspace (using file share or github pub repo)

user_map.csv
1. Export Object IDs from ADDS forrest for all user accounts being migrated from
2. Export Object IDs from Entra ID for all users being migrated to
3. Column A in csv is for source object IDs, column B is for their matching Entra ID object IDs
4. Ensure file lives in C:\workspace on all target workstations

reACL
- The user reACL script pulls the object ID matches from the user_map file in order to tell which user account matches which Entra ID account
- The script will assign all needed ACL's to the future Entra ID account based on GUID SID mapping
- This script can be run before any migration takes place. Assign the ACL well in advance of domain migration

Domain Migration
- See the top of the Unjoin/AAD Join script.  Ensure that the relevant domain admin creds are input in this script, as well as the proper name for your ppkg (IE contoso.ppkg)
- This Unjoin/Join script will disjoin from domain using DA creds
- It will then restart. This process takes roughly 15 minutes, DO NOT MANUALLY RESTART AT ANY POINT
- A total of 3 restarts will occur. One for domain disjoin, one for ppkg install, one for ppkg execution and join.
- Monitor Intune for device ingress after final restart


#IN FUTURE - Front-end web page, agent deployment to machines to view status of profile reACL, and status of dsregcmd join check to monitor state of migration
