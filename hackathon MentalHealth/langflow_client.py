"""
Helper module to forward commute event summaries to a local Langflow instance
and return the AI-generated response.
"""

import re
import requests

LANGFLOW_API_URL = (
    "http://127.0.0.1:7860/api/v1/run/0006294e-0b61-4f5b-bdb2-1225bee32b74"
)


def build_commute_summary(data: dict) -> str:
    """
    Convert a commute event payload into a human-readable summary string
    that will be sent to the Langflow flow as the user message.
    """
    return (
        f"Commute report for user '{data['user_id']}':\n"
        f"  Route       : {data['origin']} → {data['destination']}\n"
        f"  Duration    : {data['duration_minutes']} minutes\n"
        f"  Total delay : {data['total_delay_minutes']} minutes\n"
        f"  Transport   : {data['transport_mode']}\n"
        f"  Fatigue     : {data['fatigue_level_sensor']}\n"
        "Please provide a brief mental-health check-in and supportive advice "
        "based on this commute experience."
    )


def call_langflow(commute_data: dict) -> dict:
    """
    Send a commute event summary to the Langflow API and return the
    structured response.

    Parameters
    ----------
    commute_data : dict
        The validated commute event payload (matching CommuteEvent schema).

    Returns
    -------
    dict
        A dict with keys:
          - ``ai_response`` (str)  : the text produced by the Langflow flow.
          - ``raw``          (dict): the full JSON response from Langflow.

    Raises
    ------
    requests.HTTPError
        If the Langflow API returns a non-2xx status code.
    """
    summary = build_commute_summary(commute_data)

    payload = {
        "input_value": summary,
        "input_type": "chat",
        "output_type": "chat",
        "tweaks": {},
    }

    headers = {
        "x-api-key": "sk-HKr8qpaa4UivBiZ4jjOqtvNi_rIojNiucWM78YHHxGI",
    }

    response = requests.post(LANGFLOW_API_URL, json=payload, headers=headers, timeout=60)
    response.raise_for_status()

    raw = response.json()

    # Langflow wraps the answer inside outputs[0].outputs[0].results.message.text
    try:
        ai_text = (
            raw["outputs"][0]["outputs"][0]["results"]["message"]["text"]
        )
    except (KeyError, IndexError, TypeError):
        # Fallback: return the raw JSON as a string if the structure is unexpected
        ai_text = str(raw)

    # Clean up excessive newlines
    ai_text = re.sub(r"\n{2,}", "\n", ai_text).strip()

    return {"ai_response": ai_text, "raw": raw}


def parse_ai_response(ai_text: str) -> dict:
    """
    Parse the raw AI text into a structured dict with:
      - ``message``         (str)        : the opening empathy paragraph.
      - ``recommendations`` (list[str])  : individual advice sentences.

    Parsing strategy (applied in order):
    1. Explicit bullet/numbered lines (``-``, ``*``, ``1.``, ``1)``, ``1:``)
       are always treated as recommendation items.
    2. If no explicit bullets are found, the text is split on sentence
       boundaries (``।``, ``.``, ``!``, ``?`` followed by a space or EOL).
       - The first sentence (or first two short ones) becomes ``message``.
       - Every subsequent sentence that looks like advice is a recommendation.
    3. Advice-sentence detection: contains an imperative/action keyword OR
       is long enough (> 30 chars) to be a standalone tip.
    """
    # ── Step 1: try explicit bullet / numbered lines ────────────────────────
    bullet_pattern = re.compile(r"^(?:[-*•]|\d+[.):])\s+(.+)")
    lines = [ln.strip() for ln in ai_text.splitlines() if ln.strip()]

    message_lines: list[str] = []
    recommendations: list[str] = []
    collecting_recs = False

    for line in lines:
        m = bullet_pattern.match(line)
        if m:
            collecting_recs = True
            recommendations.append(m.group(1).strip())
        elif not collecting_recs:
            message_lines.append(line)
        # plain lines that appear after bullets are ignored (usually blank/headers)

    if recommendations:
        message = " ".join(message_lines).strip() or ai_text.strip()
        return {"message": message, "recommendations": recommendations}

    # ── Step 2: no bullets found → split on sentence boundaries ────────────
    # Split on ". ", "! ", "? ", "।" and keep delimiter attached to sentence.
    sentence_split = re.compile(r"(?<=[.!?।])\s+")
    raw_sentences = sentence_split.split(ai_text.strip())
    sentences = [s.strip() for s in raw_sentences if s.strip()]

    if not sentences:
        return {"message": ai_text.strip(), "recommendations": []}

    # ── Step 3: classify each sentence ──────────────────────────────────────
    # Keywords commonly found in advice/recommendation sentences (ID + EN).
    advice_keywords = re.compile(
        r"\b("
        r"coba|lakukan|ambil|minum|makan|istirahat|tidur|tarik|napas|atur|gerak|"
        r"peregangan|jalan|olahraga|dengarkan|hindari|kurangi|pastikan|ingat|"
        r"try|take|drink|eat|rest|sleep|breathe|stretch|walk|exercise|listen|"
        r"avoid|reduce|make sure|remember|consider|practice|focus|relax"
        r")\b",
        re.IGNORECASE,
    )

    # The first sentence is always the empathy message.
    # Subsequent sentences go to recommendations if they match advice keywords
    # OR are long enough to stand alone as a tip (> 30 chars).
    message = sentences[0]
    for sentence in sentences[1:]:
        clean = sentence.rstrip(".")
        if advice_keywords.search(clean) or len(clean) > 30:
            recommendations.append(clean)
        else:
            # Short non-advice sentence → append to message
            message = message.rstrip(".") + ". " + sentence

    return {"message": message.strip(), "recommendations": recommendations}
