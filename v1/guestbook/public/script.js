"use strict";
const entries = document.querySelector("#guestbook-entries");
const form = document.querySelector("#guestbook-form");
const input = document.querySelector("#guestbook-entry-content");
const button = document.querySelector("#guestbook-submit");
const status = document.querySelector("#status");
function render(messages) {
  entries.replaceChildren();
  if (!messages.length) messages = ["Be the first to leave a note."];
  for (const message of [...messages].reverse()) {
    const paragraph = document.createElement("p");
    paragraph.textContent = message;
    entries.append(paragraph);
  }
}
async function request(options) {
  const response = await fetch("api/entries", {...options, signal: AbortSignal.timeout(10000)});
  if (!response.ok) throw new Error("The guestbook could not complete that request. Please try again.");
  return response.json();
}
form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!input.value.trim()) return;
  button.disabled = true;
  status.textContent = "Saving your message…";
  try {
    render(await request({method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({message: input.value.trim()})}));
    input.value = "";
    status.textContent = "Your message has been added.";
  } catch (error) { status.textContent = error.message; }
  finally { button.disabled = false; }
});
request().then(render).catch(() => { status.textContent = "Could not load messages. Please refresh to try again."; });
