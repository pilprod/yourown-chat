# Secure AI Collaboration Platform — architecture diagrams

Concept diagrams for the platform itself: what owns state, how trust is
modeled and what a native client is responsible for.

| Diagram | What it shows |
|---|---|
| [`01-platform-center.svg`](01-platform-center.svg) | The platform as the center of the architecture: own clients, domain model, integration gateway and backend adapters |
| [`04-state-model.svg`](04-state-model.svg) | Single source of truth: platform entities, versioned domain events and projections |
| [`05-security-profiles.svg`](05-security-profiles.svg) | Conversation Security Policy: Enterprise / Restricted / Private E2EE trust profiles |
| [`06-push-mdm.svg`](06-push-mdm.svg) | Push and MDM: what every hop of the notification chain can see per profile |
