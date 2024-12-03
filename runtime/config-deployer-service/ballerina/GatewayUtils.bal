import config_deployer_service.model;

import ballerina/crypto;

import wso2/apk_common_lib as commons;

class GatewayUtils {
    private APKConf apkConf;
    private string? apiDefinition;
    private commons:Organization organization;
    private string uniqueId = "";

    public isolated function init(APKConf conf, string? apiDefinition, commons:Organization organization) {
        self.apkConf = conf;
        self.apiDefinition = apiDefinition;
        self.organization = organization;
        self.uniqueId = self.getUniqueIdForAPI(conf.name, conf.version, organization);
    }

    // public isolated function generateHTTPRoutesYaml(APKConf apkConf) returns model:HTTPRoute[]|commons:APKError {
    //     APKOperations[]? operations = apkConf.operations;

    //     if operations is APKOperations[] {
    //         if operations.length() == 0 {
    //             return e909021();
    //         }
    //         model:HTTPRoute[] httpRoutes;
    //         foreach int i in 0 ..< operations.length() {
    //             check httpRoutes.push(self.generateHTTPRoute(operations[i], i + 1))
    //         }
    //         return httpRoutes;
    //     } else {
    //         return e909021();
    //     }
    // }

    // private isolated function generateHTTPRoute(APKOperations apkOperation, int count) returns model:HTTPRoute|commons:APKError {
    //     map<model:Endpoint|()> createdEndpoints = {};
    //     EndpointConfigurations? endpointConfigurations = self.apkConf.endpointConfigurations;
    //     model:HTTPRoute httpRoute = {
    //         metadata: {
    //             name: self.uniqueId + "-" + endpointType + "-httproute-" + count.toString(),
    //             labels: self.getLabels(self.apkConf, self.organization)
    //         },
    //         spec: {
    //             parentRefs: self.generateAndRetrieveParentRefs(self.apkConf, self.uniqueId),
    //             rules: check self.generateHTTPRouteRules(apkConf, apkOperation.endpointConfigurations, endpointType, self.organization),
    //             hostnames: self.getHostNames(apkConf, uniqueId, endpointType, organization)
    //         }
    //     };

    //     return httpRoute;
    // }

    // private isolated function getLabels(APKConf api, commons:Organization organization) returns map<string> {
    //     string apiNameHash = crypto:hashSha1(api.name.toBytes()).toBase16();
    //     string apiVersionHash = crypto:hashSha1(api.'version.toBytes()).toBase16();
    //     string organizationHash = crypto:hashSha1(organization.name.toBytes()).toBase16();
    //     map<string> labels = {
    //         [API_NAME_HASH_LABEL]: apiNameHash,
    //         [API_VERSION_HASH_LABEL]: apiVersionHash,
    //         [ORGANIZATION_HASH_LABEL]: organizationHash,
    //         [MANAGED_BY_HASH_LABEL]: MANAGED_BY_HASH_LABEL_VALUE
    //     };
    //     return labels;
    // }

    // private isolated function generateAndRetrieveParentRefs(APKConf apkConf, string uniqueId) returns model:ParentReference[] {
    //     string gatewayName = gatewayConfiguration.name;
    //     string listenerName = gatewayConfiguration.listenerName;
    //     model:ParentReference[] parentRefs = [];
    //     model:ParentReference parentRef = {group: "gateway.networking.k8s.io", kind: "Gateway", name: gatewayName, sectionName: listenerName};
    //     parentRefs.push(parentRef);
    //     return parentRefs;
    // }

    // private isolated function generateHTTPRouteRules(model:APIArtifact apiArtifact, APKConf apkConf, model:Endpoint? endpoint, string endpointType, commons:Organization organization) returns model:HTTPRouteRule[]|commons:APKError|error {
    //     model:HTTPRouteRule[] httpRouteRules = [];
    //     APKOperations[]? operations = apkConf.operations;
    //     if operations is APKOperations[] {
    //         foreach APKOperations operation in operations {
    //             // model:HTTPRouteRule|model:GRPCRouteRule|() routeRule = check self.generateRouteRule(apiArtifact, apkConf, endpoint, operation, endpointType, organization);

    //             // // add matches
    //             // // add filters
    //             // // add backend refs
    //             // httpRouteRules.push(routeRule);
    //         }
    //     }
    //     return httpRouteRules;
    // }

    private isolated function createBackendRefs(EndpointConfigurations endpointConfigurations) {
        map<model:HTTPBackendRef> backendRefMap = {};
        EndpointConfiguration? productionEndpointConfig = endpointConfigurations.production;
        EndpointConfiguration? sandboxEndpointConfig = endpointConfigurations.sandbox;
    }

    private isolated function createBackendRef(EndpointConfiguration endpointConfig) returns model:HTTPBackendRef|error? {
        model:HTTPBackendRef backendRef = {
            kind: "Service",
            name: self.getHost(endpointConfig.endpoint),
            port: check self.getPort(endpointConfig.endpoint),
            group: ""
        };
        return backendRef;
    }

    private isolated function getUniqueIdForAPI(string name, string 'version, commons:Organization organization) returns string {
        string concatanatedString = string:'join("-", organization.name, name, 'version);
        byte[] hashedValue = crypto:hashSha1(concatanatedString.toBytes());
        return hashedValue.toBase16();
    }

    private isolated function constructURlFromService(string|K8sService endpoint) returns string {
        if endpoint is string {
            return endpoint;
        } else {
            return self.constructURlFromK8sService(endpoint);
        }
    }

    private isolated function constructURlFromK8sService(K8sService 'k8sService) returns string {
        return <string>k8sService.protocol + "://" + string:'join(".", <string>k8sService.name, <string>k8sService.namespace, "svc.cluster.local") + ":" + k8sService.port.toString();
    }

    private isolated function getHost(string|K8sService endpoint) returns string {
        string url;
        if endpoint is string {
            url = endpoint;
        } else {
            url = self.constructURlFromK8sService(endpoint);
        }
        string host = "";
        if url.startsWith("https://") {
            host = url.substring(8, url.length());
        } else if url.startsWith("http://") {
            host = url.substring(7, url.length());
        } else {
            return "";
        }
        int? indexOfColon = host.indexOf(":", 0);
        if indexOfColon is int {
            return host.substring(0, indexOfColon);
        } else {
            int? indexOfSlash = host.indexOf("/", 0);
            if indexOfSlash is int {
                return host.substring(0, indexOfSlash);
            } else {
                return host;
            }
        }
    }

    private isolated function getPort(string|K8sService endpoint) returns int|error {
        string url;
        if endpoint is string {
            url = endpoint;
        } else {
            url = self.constructURlFromK8sService(endpoint);
        }
        string hostPort = "";
        string protocol = "";
        if url.startsWith("https://") {
            hostPort = url.substring(8, url.length());
            protocol = "https";
        } else if url.startsWith("http://") {
            hostPort = url.substring(7, url.length());
            protocol = "http";
        } else {
            return -1;
        }
        int? indexOfSlash = hostPort.indexOf("/", 0);

        if indexOfSlash is int {
            hostPort = hostPort.substring(0, indexOfSlash);
        }
        int? indexOfColon = hostPort.indexOf(":");
        if indexOfColon is int {
            string port = hostPort.substring(indexOfColon + 1, hostPort.length());
            return check int:fromString(port);
        } else {
            if protocol == "https" {
                return 443;
            } else {
                return 80;
            }
        }
    }

}
