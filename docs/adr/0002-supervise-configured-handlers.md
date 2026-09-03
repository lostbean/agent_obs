# Configured handlers run under one-for-one supervision

<a id="adr-0002"></a>

Handlers own attachment lifecycle and process-local span state, so they run as supervised processes. One handler failure restarts that handler without restarting its peers.
