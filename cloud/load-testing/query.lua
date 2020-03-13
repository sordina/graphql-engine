wrk.method = "POST"
wrk.body   = '{"query": "query MyQuery { playlist_track { playlist_id track { name id album { id title artist { id name } } } }}"}'
wrk.headers["Content-Type"] = "application/x-www-form-urlencoded"