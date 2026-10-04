(function configureIrisPackagedAPIOfflineExample(global) {
  "use strict";

  const bootstrap = global.__IRIS_PACKAGED_API_BOOTSTRAP__;
  if (!bootstrap || typeof bootstrap !== "object") return;

  // Inert, deterministic acceptance adapter. It has no network, native, file,
  // credential, account, billing or provider authority.
  bootstrap.operations = {
    "offline.echo": {
      input: {
        type: "object",
        properties: {
          text: { type: "string", minLength: 1, maxLength: 64 },
        },
        required: ["text"],
        additionalProperties: false,
      },
      output: {
        type: "object",
        properties: {
          text: { type: "string", minLength: 1, maxLength: 64 },
          appId: { type: "string", minLength: 1, maxLength: 128 },
          projectId: { type: "string", minLength: 1, maxLength: 128 },
          revisionId: { type: "string", minLength: 1, maxLength: 80 },
        },
        required: ["text", "appId", "projectId", "revisionId"],
        additionalProperties: false,
      },
    },
  };

  bootstrap.adapter = async (request) => ({
    text: request.input.text,
    appId: request.context.appId,
    projectId: request.context.projectId,
    revisionId: request.context.revisionId,
  });
})(globalThis);
