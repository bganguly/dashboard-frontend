import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

const config    = new pulumi.Config();
const gcpConfig = new pulumi.Config("gcp");

const project       = gcpConfig.require("project");
const region        = gcpConfig.get("region")      ?? "us-central1";
const namePrefix    = config.get("namePrefix")     ?? "dash";
const frontendImage = config.require("frontendImage");
const backendUrl    = config.require("backendUrl");

const frontendService = new gcp.cloudrunv2.Service("frontend", {
  name: `${namePrefix}-frontend`,
  location: region,
  template: {
    containers: [{
      image: frontendImage,
      ports: [{ containerPort: 80 }],
      resources: { limits: { cpu: "1", memory: "512Mi" } },
      envs: [{
        name: "BACKEND_URL",
        value: backendUrl,
      }],
    }],
    scaling: { minInstanceCount: 0, maxInstanceCount: 3 },
  },
  traffics: [{ type: "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST", percent: 100 }],
});

new gcp.cloudrunv2.ServiceIamMember("frontend-public", {
  project,
  location: region,
  name: frontendService.name,
  role: "roles/run.invoker",
  member: "allUsers",
});

export const frontendUrl = frontendService.uri;
