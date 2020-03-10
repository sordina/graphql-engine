wrk.method = "POST"
wrk.body   = 'query { films(where: {title: {_like: "' .. math.random(65,90) .. '%"}}) { title id } }'
wrk.headers["Content-Type"] = "application/x-www-form-urlencoded"
