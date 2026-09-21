// Server-owned wording. New setup attempts receive changes after a relay deploy.
export function setupPrompt(ticket: string): string {
  return `Install the Hermes Jr. plugin from https://github.com/cyberculturedhq/hermes-jr-companion and connect my iPhone.

Setup ticket:
${ticket}`;
}
