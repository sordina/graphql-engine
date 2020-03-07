wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
local f = io.open("query.graphql", "r")
wrk.body = f:read("*all")
-- wrk.body   = '{"query": "query { albums { id title artist { name albums { title } } tracks { name milliseconds } } }" }'

request = function() 
    port = math.random(8888,8888)
    wrk.port = port
    return wrk.format()
end


