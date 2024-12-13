import config_deployer_service.model;

import ballerina/crypto;

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

    public isolated function generateK8sArtifacts() returns string|commons:APKError|error {
        do {
            string[] plugins = [];
            // Prepare K8s gateway specifics
            GatewayModelArtifact gatewayModelArtifact = check self.gatewayModel.prepareArtifact();
            // Generate kong gateway specific artifact
            KongGatewayArtifact kongGatewayArtifact = self.generateKongGatewayArtifact(gatewayModelArtifact);
            // Create service rate limit config
            KongRateLimitPlugin? kongRateLimitPlugin = self.generateKongRateLimitPlugin(kongGatewayArtifact, self.apkConf.rateLimit, gatewayModelArtifact.uniqueId, ());
            if kongRateLimitPlugin is KongRateLimitPlugin {
                plugins.push(kongRateLimitPlugin.metadata.name);
            }
            // Create service authentication config
            KongAuthenticationPlugin[] kongAuthenticationPlugins = check self.generateKongAuthenticationPlugin(kongGatewayArtifact, self.apkConf.authentication, gatewayModelArtifact.uniqueId, ());
            foreach KongAuthenticationPlugin kongAuthenticationPlugin in kongAuthenticationPlugins {
                plugins.push(kongAuthenticationPlugin.metadata.name);
            }
            // Set plugins as annotations
            kongGatewayArtifact.productionHttpRoutes = self.setHttpRoutePluginAnnotations(kongGatewayArtifact.productionHttpRoutes, plugins);
            kongGatewayArtifact.sandboxHttpRoutes = self.setHttpRoutePluginAnnotations(kongGatewayArtifact.sandboxHttpRoutes, plugins);

            return kongGatewayArtifact.toJsonString();
        }
        on fail var e {
            if e is commons:APKError {
                return e;
            }
            return e;
        }
    }

    private isolated function generateKongGatewayArtifact(GatewayModelArtifact gatewayModelArtifact) returns KongGatewayArtifact {
        KongGatewayArtifact kongGatewayArtifact = {
            ...gatewayModelArtifact
        };
        return kongGatewayArtifact;
    }

    private isolated function generateKongAuthenticationPlugin(KongGatewayArtifact kongGatewayArtifact, AuthenticationRequest[]? authenticationRequests, string targetRef, APKOperations? operation) returns KongAuthenticationPlugin[]|error {
        KongAuthenticationPlugin[] kongAuthenticationPlugins = [];
        if authenticationRequests is AuthenticationRequest[] {
            foreach AuthenticationRequest authenticationRequest in authenticationRequests {
                // Generate key auth plugin
                if authenticationRequest.authType == "APIKey" {
                    APIKeyAuthentication apiKeyAuthentication = check authenticationRequest.cloneWithType(APIKeyAuthentication);
                    KongKeyAuthPlugin kongKeyAuthPlugin = self.generateKeyAuthPlugin(kongGatewayArtifact, apiKeyAuthentication, targetRef, ());
                    kongAuthenticationPlugins.push(kongKeyAuthPlugin);
                }
                // Generate jwt auth plugin
                if authenticationRequest.authType == "JWT" {
                    JWTAuthentication apiJWTAuthentication = check authenticationRequest.cloneWithType(JWTAuthentication);
                    KongJWTAuthPlugin kongJWTAuthPlugin = self.generateJWTAuthPlugin(kongGatewayArtifact, apiJWTAuthentication, targetRef, ());
                    kongAuthenticationPlugins.push(kongJWTAuthPlugin);
                }
                // Generate OAuth2 auth plugin
                if authenticationRequest.authType == "OAuth2" {
                    OAuth2Authentication apiOAuth2Authentication = check authenticationRequest.cloneWithType(OAuth2Authentication);
                    KongOAuth2AuthPlugin kongOAuth2AuthPlugin = self.generateOAuth2AuthPlugin(kongGatewayArtifact, apiOAuth2Authentication, targetRef, ());
                    kongAuthenticationPlugins.push(kongOAuth2AuthPlugin);
                }
            }
        }
        return kongAuthenticationPlugins;
    }

    private isolated function generateKeyAuthPlugin(KongGatewayArtifact kongGatewayArtifact, APIKeyAuthentication authenticationRequest, string targetRefName, APKOperations? operation) returns KongKeyAuthPlugin {
        KongKeyAuthPlugin kongKeyAuthPlugin = {
            metadata: {
                name: self.gatewayModel.generatePluginRefName(operation, targetRefName, "key_auth")
            },
            enabled: authenticationRequest.enabled,
            config: {
                hide_credentials: !authenticationRequest.sendTokenToUpstream,
                key_names: [authenticationRequest.headerName],
                key_in_header: authenticationRequest.headerEnable,
                key_in_query: authenticationRequest.queryParamEnable
            }
        };
        // Add query param name to key names if it's different
        if authenticationRequest.headerName != authenticationRequest.queryParamName {
            kongKeyAuthPlugin.config.key_names.push(authenticationRequest.queryParamName);
        }
        // Add kong key auth plugin to artifact
        kongGatewayArtifact.authenticationPlugins.push(kongKeyAuthPlugin);
        return kongKeyAuthPlugin;
    }

    private isolated function generateJWTAuthPlugin(KongGatewayArtifact kongGatewayArtifact, JWTAuthentication authenticationRequest, string targetRefName, APKOperations? operation) returns KongJWTAuthPlugin {
        KongJWTAuthPlugin kongJWTAuthPlugin = {
            metadata: {
                name: self.gatewayModel.generatePluginRefName(operation, targetRefName, "jwt")
            },
            enabled: authenticationRequest.enabled,
            config: {
                header_names: [authenticationRequest.headerName]
            }
        };
        // Add kong jwt auth plugin to artifact
        kongGatewayArtifact.authenticationPlugins.push(kongJWTAuthPlugin);
        return kongJWTAuthPlugin;
    }

    private isolated function generateOAuth2AuthPlugin(KongGatewayArtifact kongGatewayArtifact, OAuth2Authentication authenticationRequest, string targetRefName, APKOperations? operation) returns KongOAuth2AuthPlugin {
        string name = self.gatewayModel.generatePluginRefName(operation, targetRefName, "oauth2");
        KongOAuth2AuthPlugin kongOAuth2AuthPlugin = {
            metadata: {
                name
            },
            enabled: authenticationRequest.enabled,
            config: {
                hide_credentials: !authenticationRequest.sendTokenToUpstream,
                auth_header_name: authenticationRequest.headerName,
                provision_key: self.generateProvisionKey(name)
            }
        };
        // Add kong oauth2 auth plugin to artifact
        kongGatewayArtifact.authenticationPlugins.push(kongOAuth2AuthPlugin);
        return kongOAuth2AuthPlugin;
    }

    private isolated function generateProvisionKey(string pluginName) returns string {
        byte[] hexBytes = string:toBytes(pluginName);
        return crypto:hashSha1(hexBytes).toBase16();
    }

    private isolated function generateKongRateLimitPlugin(KongGatewayArtifact kongGatewayArtifact, RateLimit? rateLimit, string targetRefName, APKOperations? operation) returns KongRateLimitPlugin|() {
        if rateLimit is RateLimit {
            string rateLimitUnit = rateLimit.unit.toLowerAscii();
            KongRateLimitPlugin kongRateLimitPlugin = {
                metadata: {
                    name: self.gatewayModel.generatePluginRefName(operation, targetRefName, "rate_limiting")
                },
                config: {
                    [rateLimitUnit]: rateLimit.requestsPerUnit
                }
            };
            // Add kong rate limit plugin to artifact
            kongGatewayArtifact.rateLimits.push(kongRateLimitPlugin);
            return kongRateLimitPlugin;
        } else {
            return ();
        }
    }

    private isolated function setHttpRoutePluginAnnotations(model:HTTPRoute[] httpRoutes, string[] plugins) returns model:HTTPRoute[] {
        foreach model:HTTPRoute httpRoute in httpRoutes {
            map<string>? annotations = httpRoute.metadata.annotations;
            if annotations == () {
                annotations = {};
            }
            if annotations is map<string> {
                string annotationsString = annotations["konghq.com/plugins"] ?: "";
                // Merge new and previous annotations
                annotationsString = string:'join(",", ...plugins) + "," + annotationsString;
                // Remove trailing comma (if exists)
                if annotationsString.endsWith(",") {
                    annotationsString = annotationsString.substring(0, annotationsString.length() - 1);
                }
                // Set plugins to http route
                httpRoute.metadata.annotations["konghq.com/plugins"] = annotationsString;
            }
        }
        return httpRoutes;
    }

}

