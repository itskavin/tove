# Answer-quality eval

Realistic questions across intents (local health and food, shopping, travel, how-to, news, money, learning, people,
homework, quick facts, and a two-turn ADHD assessment + screening case), each with a reference rubric: what the best
ChatGPT-style answer would contain.

1. **Run** a bridge build against a real Hermes. `run_eval.py` starts a **scratch** bridge from the script you name, on
   a free port with a temporary data directory, so a production bridge is never touched. It reads only Hermes' address
   and key (and the title proxy settings) from the env file you name.

   ```sh
   python3 run_eval.py --bridge ../gpt-live-bridge.py --env /path/to/bridge.env --out runs/after \
       --places-db /path/to/places.sqlite            # optional: an extract from places_fetch.py
   ```

   Each case is one chat; turns are sent with `"ui": 2`, medium effort and the questions file's sample location
   (`--location "Label@lat,lng"`, or `--no-location`), with a pause between cases (`--pause`, default 8 s) so the
   search engines behind Hermes are not flooded. Output: `results.json` (text, timings, tools, usage, and
   `/api/places/info` for any `place:` ids) and one markdown file per case.

2. **Judge** with any OpenAI-compatible model (by default the bridge's title proxy, `TITLE_API_URL`/`TITLE_API_KEY`):

   ```sh
   python3 judge.py --env /path/to/bridge.env runs/before runs/after      # --model to choose the judge
   ```

   Each case gets 1–10 for usefulness, accuracy, structure, presentation, actionability and speed, an overall score
   and a short rationale (`scores.json`); the table lists averages per intent and the ADHD case.

3. **Render** every reply as a phone-sized PNG with the app's real widgets:

   ```sh
   cd ../../app && TOVE_RENDER_IN=/path/runs/after/results.json TOVE_RENDER_OUT=/path/renders \
       flutter test test/tool/render_replies_test.dart        # TOVE_RENDER_THEME=both, TOVE_RENDER_ONLY=adhd
   ```

The places_search tool is a Hermes plugin: Hermes uses it only when `hermes-places` is installed there. Results and
renders hold real answers (names, places, possibly personal context from Hermes' memory): keep them out of the
repository.
