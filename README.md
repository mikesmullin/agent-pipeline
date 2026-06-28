# Agent Pipeline — Documentation site (`docs` branch)

This is an **orphan `docs` branch** of the `agent-pipeline` repo that contains
**only the generated static documentation site** — ready to publish on GitHub
Pages with zero build step.

## What's here

    index.html      the documentation (single self-contained page)
    style.css       the "Crunchy Code Fuel" cereal-box theme
    assets/         the logo
    .nojekyll       tell GitHub Pages to serve the files as-is (no Jekyll)

## Publish on GitHub Pages

1. Push this `docs` branch to the remote.
2. Repo -> Settings -> Pages.
3. Source: "Deploy from a branch" -> Branch `docs` -> folder `/ (root)`.
4. Save. The site serves at https://<user>.github.io/<repo>/

## Local preview

    python3 -m http.server 8080   # then open http://localhost:8080

or just open index.html directly.

## Editing

A single hand-authored index.html + style.css. The content tracks the framework
contract in docs/ARCHITECTURE.md, docs/SCHEMA.md, and docs/ACTIVITY.md on `main`.
When the framework's public surface changes, update the matching section here.
