from fastapi import FastAPI, Request
import base64
import json

app = FastAPI()

@app.get("/")
async def root(request: Request):
    try:
        id_token = request.headers.get('x-ms-token-aad-id-token')
        id_token_split = id_token.split(".")
        b64_token_claims = id_token_split[1] + '==' # add padding since python will ignore extra
    
        token_claims =  base64.b64decode(b64_token_claims)
        token_claims_json = json.loads(token_claims)
        tid = token_claims_json["tid"]
        return {"tid": tid}
    except Exception as e:
        return {"error": str(e)}

@app.get("/headers")
async def headers(request: Request):
    headers = request.headers
    return {"headers": headers}
