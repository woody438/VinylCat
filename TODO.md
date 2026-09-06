# VinylCat — to-do (from Woody's walkthrough)

- [x] Setup wizard › Vision model: no clickable link to open the page that generates the key
      (there is a GET A KEY button, but the "key from platform.openai.com/api-keys" / aistudio.google.com/apikey text should
      itself be a clickable link, and check the button actually shows in the real window).
- [x] Auto-capture unreliable: fires when things move in/out of frame quickly. Add alignment guides on the preview,
      require phash-stable steady window (~1 s), and a Manual mode (no auto; "capture" / space bar takes the shot).
- [x] Voice button top-right doesn't do anything — make it a real start/stop toggle with the reason shown when it can't listen.
- [x] B-side capture only when needed: skip extra shots on singles after a confident Discogs match (tracklist known);
      ask for the B-side only when ambiguous / not found. LPs: front + back only by default.
- [x] iPhone Continuity Camera selectable but shows no video (FaceTime HD works) — check session preset / active format on switch.
