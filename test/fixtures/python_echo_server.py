import json
import sys


def error_response(request_id, code, message):
    return {
        "jsonrpc": "2.0",
        "error": {"code": code, "message": message},
        "id": request_id,
    }


for line in sys.stdin:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        print(json.dumps(error_response(None, -32700, "Parse error"), separators=(",", ":")), flush=True)
        continue

    request_id = request.get("id")
    if "id" not in request:
        continue

    if request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
        response = error_response(request_id, -32600, "Invalid Request")
    elif request["method"] == "echo":
        response = {"jsonrpc": "2.0", "result": request.get("params"), "id": request_id}
    elif request["method"] == "add":
        params = request.get("params")
        if isinstance(params, list) and all(isinstance(item, int) for item in params):
            response = {"jsonrpc": "2.0", "result": sum(params), "id": request_id}
        else:
            response = error_response(request_id, -32602, "Invalid params")
    else:
        response = error_response(request_id, -32601, "Method not found")

    print(json.dumps(response, separators=(",", ":")), flush=True)
