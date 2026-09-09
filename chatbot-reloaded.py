import json
import time
import requests

URL = "http://127.0.0.1:8080/v1/chat/completions"
MODEL = "qwen-patch-ai"

history = []

print("=" * 60)
print(" Qwen3-8B Local Test Chat")
print(" Type: exit to quit | clear to reset conversation")
print("=" * 60)

while True:
    try:
        user_input = input("\nYou: ").strip()

        if not user_input:
            continue

        if user_input.lower() in {"exit", "quit"}:
            break

        if user_input.lower() == "clear":
            history.clear()
            print("Conversation cleared.")
            continue

        history.append({
            "role": "user",
            "content": user_input
        })

        payload = {
            "model": MODEL,
            "messages": history,
            "stream": True,
            "max_tokens": 200,

            # Important for CPU-only Qwen3 testing
            "chat_template_kwargs": {
                "enable_thinking": False
            },

            "temperature": 0.7,
            "top_p": 0.8
        }

        print("\nQwen: ", end="", flush=True)

        start = time.time()
        full_answer = ""

        response = requests.post(
            URL,
            json=payload,
            stream=True,
            timeout=(5, 600)
        )

        response.raise_for_status()

        for line in response.iter_lines(decode_unicode=True):
            if not line:
                continue

            if not line.startswith("data: "):
                continue

            data = line[6:]

            if data == "[DONE]":
                break

            try:
                event = json.loads(data)

                delta = (
                    event.get("choices", [{}])[0]
                    .get("delta", {})
                    .get("content")
                )

                if delta:
                    print(delta, end="", flush=True)
                    full_answer += delta

            except json.JSONDecodeError:
                continue

        elapsed = time.time() - start

        print(f"\n\n[Completed in {elapsed:.1f}s]")

        if full_answer:
            history.append({
                "role": "assistant",
                "content": full_answer
            })

    except requests.exceptions.ConnectionError:
        print("\nERROR: Cannot connect to Qwen server.")
        print("Check: systemctl status qwen-ai.service")

    except requests.exceptions.ReadTimeout:
        print("\nERROR: Model response timed out.")

    except requests.exceptions.RequestException as e:
        print(f"\nHTTP ERROR: {e}")

    except KeyboardInterrupt:
        print("\nStopped.")
        break
