import requests

URL = "http://127.0.0.1:8080/v1/chat/completions"
MODEL = "qwen-patch-ai"

history = []

print("Qwen test chat")
print("Type 'exit' to quit.\n")

while True:
    user_input = input("You: ").strip()

    if user_input.lower() in {"exit", "quit"}:
        break

    history.append({
        "role": "user",
        "content": user_input
    })

    response = requests.post(
        URL,
        headers={"Content-Type": "application/json"},
        json={
            "model": MODEL,
            "messages": history,
            "max_tokens": 300
        },
        timeout=120
    )

    response.raise_for_status()

    answer = response.json()["choices"][0]["message"]["content"]

    print(f"\nQwen: {answer}\n")

    history.append({
        "role": "assistant",
        "content": answer
    })
