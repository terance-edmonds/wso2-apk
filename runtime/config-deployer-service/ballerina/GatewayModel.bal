import config_deployer_service.model;

import ballerina/log;
import ballerina/regex;

import wso2/apk_common_lib as commons;

class GatewayModel {
    private APKConf apkConf;
    private string? apiDefinition;
    private commons:Organization organization;
    private string uniqueId = "test-unique-id";

    public isolated function init(APKConf conf, string? apiDefinition, commons:Organization organization) {
        self.apkConf = conf;
        self.apiDefinition = apiDefinition;
        self.organization = organization;
    }

    // generate the endpoints for each environment
    public isolated function prepareArtifact() returns string|commons:APKError {
        do {
            map<model:Endpoint|()> createdEndpoints = {};
            EndpointConfigurations? endpointConfigurations = self.apkConf.endpointConfigurations;
            if (endpointConfigurations is EndpointConfigurations) {
                createdEndpoints = check self.createEndpoints(endpointConfigurations, ());
            }
            model:HTTPRoute[] productionHttpRoutes = check self.generateRoutes(createdEndpoints.hasKey(PRODUCTION_TYPE) ? createdEndpoints.get(PRODUCTION_TYPE) : (), PRODUCTION_TYPE);
            return productionHttpRoutes.toJsonString();
        } on fail var e {
            log:printError("Internal Error occured", e);
            return e909022("Internal Error occured", e);
        }
    }

    public isolated function generateRoutes(model:Endpoint? endpoint, string endpointType) returns model:HTTPRoute[]|commons:APKError {
        model:HTTPRoute[] httpRoutes = [];
        APKOperations[] apiOperations = self.apkConf.operations ?: [];
        APKOperations[][] operationsArray = [];
        // partition the http routes (max 8 rules per route)
        int row = 0;
        int column = 0;
        foreach APKOperations item in apiOperations {
            if column > 7 {
                row = row + 1;
                column = 0;
            }
            operationsArray[row][column] = item;
            column = column + 1;
        }
        int count = 1;
        foreach APKOperations[] item in operationsArray {
            APKOperations[] operations = item.clone();
            model:HTTPRoute httpRoute = check self.putRoutesForPartition(operations, endpoint, endpointType, count);
            httpRoutes.push(httpRoute);
            count = count + 1;
        }
        return httpRoutes;
    }

    // generate endpoints for each environment
    private isolated function createEndpoints(EndpointConfigurations endpointConfigurations, string? endpointType) returns map<model:Endpoint>|error {
        map<model:Endpoint> createdEndpoints = {};
        EndpointConfiguration? productionEndpointConfig = endpointConfigurations.production;
        EndpointConfiguration? sandboxEndpointConfig = endpointConfigurations.sandbox;
        if (endpointType == () || endpointType === SANDBOX_TYPE) {
            if (sandboxEndpointConfig is EndpointConfiguration) {
                createdEndpoints[SANDBOX_TYPE] = {
                    name: self.getHost(sandboxEndpointConfig.endpoint),
                    url: self.constructURlFromService(sandboxEndpointConfig.endpoint)
                };
            }
        }
        if (endpointType == () || endpointType === PRODUCTION_TYPE) {
            if (productionEndpointConfig is EndpointConfiguration) {
                createdEndpoints[PRODUCTION_TYPE] = {
                    name: self.getHost(productionEndpointConfig.endpoint),
                    url: self.constructURlFromService(productionEndpointConfig.endpoint)
                };
            }
        }
        return createdEndpoints;
    }

    // create http route
    private isolated function putRoutesForPartition(APKOperations[] operations, model:Endpoint? endpoint, string endpointType, int count) returns model:HTTPRoute|commons:APKError {
        model:HTTPRoute httpRoute = {
            metadata: {
                name: self.uniqueId + "-" + endpointType + "-httproute-" + count.toString()
            },
            spec: {
                parentRefs: self.generateAndRetrieveParentRefs(),
                rules: check self.generateHTTPRouteRules(operations, endpoint, endpointType)
            }
        };
        return httpRoute;
    }

    // generate http route rules
    private isolated function generateHTTPRouteRules(APKOperations[]? operations, model:Endpoint? endpoint, string endpointType) returns model:HTTPRouteRule[]|commons:APKError {
        model:HTTPRouteRule[] httpRouteRules = [];
        if operations is APKOperations[] {
            foreach APKOperations operation in operations {
                model:HTTPRouteRule? httpRouteRule = check self.generateRouteRule(operation, endpoint, endpointType);
                if httpRouteRule is model:HTTPRouteRule {
                    httpRouteRules.push(httpRouteRule);
                }
            }
        }
        return httpRouteRules;
    }

    private isolated function generateRouteRule(APKOperations operation, model:Endpoint? endpoint, string endpointType) returns model:HTTPRouteRule|()|commons:APKError {
        do {
            EndpointConfigurations? endpointConfig = operation.endpointConfigurations;
            model:Endpoint? endpointToUse = ();
            if endpointConfig is EndpointConfigurations {
                map<model:Endpoint> operationalLevelEndpoint = check self.createEndpoints(endpointConfig, endpointType);
                if operationalLevelEndpoint.hasKey(endpointType) {
                    endpointToUse = operationalLevelEndpoint.get(endpointType);
                }
            } else {
                if endpoint is model:Endpoint {
                    endpointToUse = endpoint;
                }
            }
            if endpointToUse != () {
                model:HTTPRouteRule httpRouteRule = {
                    matches: check self.retrieveHTTPMatches(operation, endpointType)
                };
                return httpRouteRule;
            } else {
                return ();
            }
        } on fail var e {
            log:printError("Internal Error occured", e);
            return e909022("Internal Error occured", e);
        }
    }

    private isolated function retrieveHTTPMatches(APKOperations operation, string endpointType) returns model:HTTPRouteMatch[]|error {
        model:HTTPRouteMatch[] httpRouteMatch = [];
        model:HTTPRouteMatch httpRoute = self.retrieveHttpRouteMatch(operation);
        httpRouteMatch.push(httpRoute);
        return httpRouteMatch;
    }

    private isolated function retrieveHttpRouteMatch(APKOperations operation) returns model:HTTPRouteMatch {
        return {method: <string>operation.verb, path: {'type: "RegularExpression", value: self.retrievePathPrefix(operation.target ?: "/*")}};
    }

    public isolated function retrievePathPrefix(string operation) returns string {
        string[] splitValues = regex:split(operation, "/");
        string generatedPath = "";
        if (operation == "/*") {
            return "(.*)";
        } else if operation == "/" {
            return "/";
        }
        foreach string pathPart in splitValues {
            if pathPart.trim().length() > 0 {
                // path contains path param
                if regex:matches(pathPart, "\\{.*\\}") {
                    generatedPath = generatedPath + "/" + regex:replaceAll(pathPart.trim(), "\\{.*\\}", "(.*)");
                } else {
                    generatedPath = generatedPath + "/" + pathPart;
                }
            }
        }

        if generatedPath.endsWith("/*") {
            int lastSlashIndex = <int>generatedPath.lastIndexOf("/", generatedPath.length());
            generatedPath = generatedPath.substring(0, lastSlashIndex) + "(.*)";
        }
        return generatedPath.trim();
    }

    private isolated function generateAndRetrieveParentRefs() returns model:ParentReference[] {
        string gatewayName = gatewayConfiguration.name;
        string listenerName = gatewayConfiguration.listenerName;
        model:ParentReference[] parentRefs = [];
        model:ParentReference parentRef = {group: "gateway.networking.k8s.io", kind: "Gateway", name: gatewayName, sectionName: listenerName};
        parentRefs.push(parentRef);
        return parentRefs;
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

}

