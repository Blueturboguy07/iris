# Export queue

This is a small, headless slice of an export screen. The queue owns durable
job state, the worker is supplied by the caller, and the controller gives a UI
status panel a stable view. There is deliberately no network client here.

Read `docs/QUEUE.md` before changing the queue contract.

Run the checks with:

    npm run build
    npm test
