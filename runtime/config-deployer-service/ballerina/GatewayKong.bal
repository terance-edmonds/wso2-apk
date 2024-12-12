import config_deployer_service.model;

import wso2/apk_common_lib as commons;

public class GatewayKong {
    private final string apiVersion = "configuration.konghq.com/v1";
    private APKConf apkConf;
    private string? apiDefinition;
    private commons:Organization organization;
    private GatewayModel gatewayModel;

    private GatewayConfigurations gatewayConfig = {
        name: "kong",
        listenerName: "https"
    };

    public isolated function init(APKConf conf, string? apiDefinition, commons:Organization organization) {
        self.apkConf = conf;
        self.apiDefinition = apiDefinition;
        self.organization = organization;
        self.gatewayModel = new (self.apkConf, self.apiDefinition, self.organization, self.gatewayConfig);
    }

    public isolated function generateK8sArtifacts() returns string|commons:APKError {
        do {
            // Prepare K8s gateway specifics
            GatewayModelArtifact gatewayModelArtifact = check self.gatewayModel.prepareArtifact();
            // Generate kong gateway specific artifact
            KongGatewayArtifact kongGatewayArtifact = self.generateKongGatewayArtifact(gatewayModelArtifact);
            // Create and add global rate limit config
            self.setKongRateLimitPlugin(kongGatewayArtifact, self.apkConf.rateLimit, gatewayModelArtifact.uniqueId, ());

            return kongGatewayArtifact.toJsonString();
        }
        on fail var e {
            if e is commons:APKError {
                return e;
            }
        }
    }

    private isolated function generateKongGatewayArtifact(GatewayModelArtifact gatewayModelArtifact) returns KongGatewayArtifact {
        KongGatewayArtifact kongGatewayArtifact = {
            ...gatewayModelArtifact
        };
        return kongGatewayArtifact;
    }

    private isolated function getRateLimitForHttpRoutes(model:HTTPRoute[] httpRoutes, string pluginName) returns model:HTTPRoute[] {
        foreach model:HTTPRoute httpRoute in httpRoutes {
            map<string>? annotations = httpRoute.metadata.annotations;
            if annotations == () {
                annotations = {};
            }
            if annotations is map<string> {
                string pluginAnnotation = annotations["konghq.com/plugins"] ?: "";
                httpRoute.metadata.annotations["konghq.com/plugins"] = pluginAnnotation + "," + pluginName;
            }
        }
        return httpRoutes;
    }

    private isolated function setKongRateLimitPlugin(KongGatewayArtifact kongGatewayArtifact, RateLimit? rateLimit, string targetRef, APKOperations? operation) {
        if rateLimit is RateLimit {
            KongRateLimitPlugin? kongRateLimitPlugin = self.generateKongRateLimitPlugin(kongGatewayArtifact, rateLimit, targetRef, ());
            if kongRateLimitPlugin is KongRateLimitPlugin {
                // Set rate limit plugin to production http routes
                kongGatewayArtifact.productionHttpRoutes = self.getRateLimitForHttpRoutes(kongGatewayArtifact.productionHttpRoutes, kongRateLimitPlugin.metadata.name);
                // Set rate limit plugin to sandbox http routes
                kongGatewayArtifact.sandboxHttpRoutes = self.getRateLimitForHttpRoutes(kongGatewayArtifact.sandboxHttpRoutes, kongRateLimitPlugin.metadata.name);
            }
        }
    }

    private isolated function generateKongRateLimitPlugin(KongGatewayArtifact kongGatewayArtifact, RateLimit rateLimit, string targetRefName, APKOperations? operation) returns KongRateLimitPlugin|() {
        string rateLimitUnit = rateLimit.unit.toLowerAscii();
        KongRateLimitPlugin kongRateLimitPlugin = {
            metadata: {
                name: self.gatewayModel.generateRateLimitPolicyRefName(operation, targetRefName)
            },
            config: {
                [rateLimitUnit]: rateLimit.requestsPerUnit
            }
        };
        // Add kong rate limit plugin to artifact
        kongGatewayArtifact.rateLimits.push(kongRateLimitPlugin);
        return kongRateLimitPlugin;
    }

}

