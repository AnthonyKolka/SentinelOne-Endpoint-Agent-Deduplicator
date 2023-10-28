# SentinelOne-Endpoint-Agent-Deduplicator
Script that uses SentinelOne API to decommission duplicated endpoint / agent instances from agent ID changes. Requires an API key.

## Usage:
`>Remove-SentinelOneDuplicateAgents.ps1 [[-ApiKey] <string] [[-SiteFilter] <string[]>] [[-LogPath] <string>] [-WriteLog] [-Whatif]`
