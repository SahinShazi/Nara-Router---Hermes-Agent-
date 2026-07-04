import os
import httpx
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import StreamingResponse

# FastAPI অ্যাপ ইনিশিয়ালাইজেশন
app = FastAPI(title="Groq Cloudflare-Bypass Proxy")

# আসল Groq API-এর কানেকশন পাথ
GROQ_API_URL = "https://api.groq.com/openai"

# ক্লাউডফ্লেয়ার ১০১০ ব্লক এড়াতে কাস্টম ব্রাউজার হেডার কনফিগারেশন
CUSTOM_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "application/json, text/event-stream",
    "Accept-Language": "en-US,en;q=0.9",
    "Origin": "https://api.groq.com",
    "Referer": "https://api.groq.com/"
}

# অ্যাসিনক্রোনাস HTTPX ক্লায়েন্ট তৈরি (যা হেডার রিডাইরেক্ট করবে)
http_client = httpx.AsyncClient(base_url=GROQ_API_URL, headers=CUSTOM_HEADERS)

@app.on_event("shutdown")
async def shutdown_event():
    # অ্যাপ বন্ধ হওয়ার সময় কানেকশন রিলিজ করা
    await http_client.aclose()

# ১. চ্যাট কমপ্লিশন রাউট (Hermes Agent এই পোর্টে চ্যাট ডেটা পাঠাবে)
@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    # হার্মেস-এর পাঠানো পেলোড (Payload) রিড করা
    body = await request.body()
    
    # ইনকামিং রিকোয়েস্ট থেকে অথরাইজেশন হেডার (API Key) সংগ্রহ করা
    auth_header = request.headers.get("Authorization")
    if not auth_header:
        raise HTTPException(status_code=401, detail="Missing Authorization Header")

    # আসল Groq-এর জন্য হেডার তৈরি (কাস্টম ব্রাউজার হেডারসহ)
    headers = {
        "Authorization": auth_header,
        "Content-Type": "application/json"
    }

    # আমাদের কাস্টম হেডার দিয়ে Groq-এর কাছে রিকোয়েস্টটি রিডাইরেক্ট করা
    req = http_client.build_request(
        "POST",
        "/v1/chat/completions",
        content=body,
        headers=headers,
        timeout=60.0
    )
    
    response = await http_client.send(req, stream=True)

    # জেনারেটর ব্যবহার করে এআই-এর আউটপুট রিয়েল-টাইমে স্ট্রিম ব্যাক করা
    async def stream_generator():
        async for chunk in response.aiter_bytes():
            yield chunk
        await response.aclose()

    return StreamingResponse(
        stream_generator(),
        status_code=response.status_code,
        headers=dict(response.headers)
    )

# ২. মডেল লিস্ট রাউট (মডেল ভ্যালিডেশনের জন্য হার্মেস এটি চেক করে)
@app.get("/v1/models")
async def list_models(request: Request):
    auth_header = request.headers.get("Authorization")
    if not auth_header:
        raise HTTPException(status_code=401, detail="Missing Authorization Header")

    headers = {"Authorization": auth_header}
    
    response = await http_client.get("/v1/models", headers=headers)
    return response.json()

# ৩. হেলথ চেক রাউট
@app.get("/")
async def health_check():
    return {"status": "ok", "proxy": "Groq Cloudflare-Bypass Proxy is Running"}

if __name__ == "__main__":
    import uvicorn
    # আপনার লগে থাকা পোর্টের রিকোয়ারমেন্ট অনুযায়ী এটি ৮০০১ পোর্টে রান করবে
    uvicorn.run(app, host="127.0.0.1", port=8001)