import config_deployer_service.model;

import ballerina/crypto;
import ballerina/log;
import ballerina/regex;
import ballerina/uuid;

import wso2/apk_common_lib as commons;

class GatewayModel {
    private APKConf apkConf;
    private string? apiDefinition;
    private commons:Organization organization;
    private GatewayConfigurations gatewayConfigurations;
    private GatewayModelArtifact gatewayModelArtifact = {
        uniqueId: "",
        name: "",
        version: "",
        organization: ""
    };

    public isolated function init(APKConf conf, string? apiDefinition, commons:Organization organization, GatewayConfigurations gatewayConfigurations) {
        self.apkConf = conf;
        self.apiDefinition = apiDefinition;
        self.organization = organization;
        self.gatewayConfigurations = gatewayConfigurations;
        self.gatewayModelArtifact = {uniqueId: self.getUniqueId(self.apkConf.name, self.apkConf.version, self.organization), name: self.apkConf.name, version: self.apkConf.version, organization: self.organization.name};
    }

    // Prepare K8s artifacts
    public isolated function prepareArtifact() returns GatewayModelArtifact|commons:APKError {
        do {
            map<model:Endpoint|()> createdEndpoints = {};
            EndpointConfigurations? endpointConfigurations = self.apkConf.endpointConfigurations;
            if (endpointConfigurations is EndpointConfigurations) {
                createdEndpoints = check self.createEndpoints(endpointConfigurations, ());
            }
            // create Route CRs
            check self.generateRoutes(createdEndpoints.hasKey(SANDBOX_TYPE) ? createdEndpoints.get(SANDBOX_TYPE) : (), SANDBOX_TYPE);
            check self.generateRoutes(createdEndpoints.hasKey(PRODUCTION_TYPE) ? createdEndpoints.get(PRODUCTION_TYPE) : (), PRODUCTION_TYPE);
            return self.gatewayModelArtifact;
        } on fail var e {
            log:printError("Internal Error occurred", e);
            return e909022("Internal Error occurred", e);
        }
    }

    // Get a unique ID for the config
    public isolated function getUniqueId(string name, string 'version, commons:Organization organization) returns string {
        string concatenatedString = string:'join("-", organization.name, name, 'version);
        byte[] hashedValue = crypto:hashSha1(concatenatedString.toBytes());
        return hashedValue.toBase16();
    }

    // Generate the routes
    public isolated function generateRoutes(model:Endpoint? endpoint, string endpointType) returns commons:APKError|error? {
        // Partition the routes (max 8 rules per route)
        APKOperations[] apiOperations = self.apkConf.operations ?: [];
        APKOperations[][] operationsArray = [];
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
            // Put each 8 set of operations into one route
            APKOperations[] operations = item.clone();
            check self.putRoutesForPartition(operations, endpoint, endpointType, count);
            count = count + 1;
        }
    }

    // Put a set of operations into route
    private isolated function putRoutesForPartition(APKOperations[] operations, model:Endpoint? endpoint, string endpointType, int count) returns commons:APKError|error? {
        if self.apkConf.'type == API_TYPE_REST {
            model:HTTPRoute httpRoute = {
                metadata: {
                    name: self.gatewayModelArtifact.uniqueId + "-" + endpointType + "-httproute-" + count.toString(),
                    labels: self.generateApiLabel()
                },
                spec: {
                    parentRefs: self.generateParentRefs(self.gatewayConfigurations),
                    rules: check self.generateHTTPRouteRules(operations, endpoint, endpointType),
                    hostnames: self.getHostNames(self.gatewayModelArtifact.uniqueId, endpointType)
                }
            };
            if httpRoute.spec.rules.length() > 0 {
                if endpointType === PRODUCTION_TYPE {
                    self.gatewayModelArtifact.productionHttpRoutes.push(httpRoute);
                } else {
                    self.gatewayModelArtifact.sandboxHttpRoutes.push(httpRoute);
                }
            }
        } else if self.apkConf.'type == API_TYPE_GRPC {
            model:GRPCRoute grpcRoute = {
                metadata: {
                    name: self.gatewayModelArtifact.uniqueId + "-" + endpointType + "-grpcroute-" + count.toString(),
                    labels: self.generateApiLabel()
                },
                spec: {
                    parentRefs: self.generateParentRefs(self.gatewayConfigurations),
                    rules: check self.generateGRPCRouteRules(operations, endpoint, endpointType),
                    hostnames: self.getHostNames(self.gatewayModelArtifact.uniqueId, endpointType)
                }
            };
            if grpcRoute.spec.rules.length() > 0 {
                if endpointType === PRODUCTION_TYPE {
                    self.gatewayModelArtifact.productionGrpcRoutes.push(grpcRoute);
                } else {
                    self.gatewayModelArtifact.sandboxGrpcRoutes.push(grpcRoute);
                }
            }
        } else {
            return e909018("Invalid API Type specified");
        }
    }

    // Generate rate limit policy name
    public isolated function generatePluginRefName(APKOperations? operation, string targetRef, string pluginName) returns string {
        string concatenatedString = pluginName;
        if operation is APKOperations {
            if (operation.target is string) {
                byte[] hexBytes = string:toBytes(<string>operation.target + <string>operation.verb);
                string operationTargetHash = crypto:hashSha1(hexBytes).toBase16();
                concatenatedString = concatenatedString + "-" + operationTargetHash;
            }
            return "route-" + concatenatedString + "-" + targetRef;
        } else {
            return "service-" + concatenatedString + "-" + targetRef;
        }
    }

    // Generate endpoints for each environment
    private isolated function createEndpoints(EndpointConfigurations endpointConfigurations, string? endpointType) returns map<model:Endpoint>|error {
        map<model:Endpoint> createdEndpoints = {};
        EndpointConfiguration? productionEndpointConfig = endpointConfigurations.production;
        EndpointConfiguration? sandboxEndpointConfig = endpointConfigurations.sandbox;
        if (endpointType == () || endpointType === SANDBOX_TYPE) {
            if (sandboxEndpointConfig is EndpointConfiguration) {
                createdEndpoints[SANDBOX_TYPE] = {
                    name: getHost(sandboxEndpointConfig.endpoint),
                    url: constructURlFromService(sandboxEndpointConfig.endpoint)
                };
            }
        }
        if (endpointType == () || endpointType === PRODUCTION_TYPE) {
            if (productionEndpointConfig is EndpointConfiguration) {
                createdEndpoints[PRODUCTION_TYPE] = {
                    name: getHost(productionEndpointConfig.endpoint),
                    url: constructURlFromService(productionEndpointConfig.endpoint)
                };
            }
        }
        return createdEndpoints;
    }

    private isolated function generateApiLabel() returns map<string> {
        map<string> labels = {
            "apiName": self.apkConf.name,
            "version": self.apkConf.version,
            "basePath": self.apkConf.basePath,
            "defaultVersion": self.apkConf.defaultVersion.toString()
        };
        if self.apkConf.environment is string {
            labels["environment"] = <string>self.apkConf.environment;
        }
        if self.apkConf.definitionPath is string {
            labels["definitionPath"] = <string>self.apkConf.definitionPath;
        }
        return labels;
    }

    // Generate http route rules
    private isolated function generateHTTPRouteRules(APKOperations[]? operations, model:Endpoint? endpoint, string endpointType) returns model:HTTPRouteRule[]|commons:APKError {
        model:HTTPRouteRule[] httpRouteRules = [];
        if operations is APKOperations[] {
            foreach APKOperations operation in operations {
                model:HTTPRouteRule|model:GRPCRouteRule? httpRouteRule = check self.generateRouteRule(operation, endpoint, endpointType, API_TYPE_REST);
                if httpRouteRule is model:HTTPRouteRule {
                    httpRouteRules.push(httpRouteRule);
                }
            }
        }
        return httpRouteRules;
    }

    // Generate grpc route rules
    private isolated function generateGRPCRouteRules(APKOperations[]? operations, model:Endpoint? endpoint, string endpointType) returns model:GRPCRouteRule[]|commons:APKError {
        model:GRPCRouteRule[] grpcRouteRules = [];
        if operations is APKOperations[] {
            foreach APKOperations operation in operations {
                model:HTTPRouteRule|model:GRPCRouteRule? grpcRouteRule = check self.generateRouteRule(operation, endpoint, endpointType, API_TYPE_GRPC);
                if grpcRouteRule is model:GRPCRouteRule {
                    grpcRouteRules.push(grpcRouteRule);
                }
            }
        }
        return grpcRouteRules;
    }

    // Generate http route rule
    private isolated function generateRouteRule(APKOperations operation, model:Endpoint? endpoint, string endpointType, string apiType) returns model:HTTPRouteRule|model:GRPCRouteRule|()|commons:APKError {
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
                if apiType == API_TYPE_REST {
                    model:HTTPRouteFilter[] filters = [];
                    boolean hasRedirectPolicy = false;
                    [filters, hasRedirectPolicy] = self.generateFilters(endpointToUse, operation, endpointType);
                    model:HTTPRouteRule httpRouteRule = {
                        matches: check self.retrieveHTTPMatches(operation, endpointType),
                        filters
                    };
                    if !hasRedirectPolicy {
                        httpRouteRule.backendRefs = self.retrieveGeneratedBackendRefs(endpointToUse, endpointType);
                    }
                    return httpRouteRule;
                } else if apiType == API_TYPE_GRPC {
                    model:GRPCRouteRule grpcRouteRule = {
                        matches: check self.retrieveGRPCMatches(operation, endpointType),
                        backendRefs: self.retrieveGeneratedBackendRefs(endpointToUse, endpointType)
                    };
                    return grpcRouteRule;
                } else {
                    return e909018("Invalid API Type specified");
                }
            } else {
                return ();
            }
        } on fail var e {
            log:printError("Internal Error occurred", e);
            return e909022("Internal Error occurred", e);
        }
    }

    // Retrieve the HTTP matches for a given operation
    private isolated function retrieveHTTPMatches(APKOperations operation, string endpointType) returns model:HTTPRouteMatch[]|error {
        model:HTTPRouteMatch[] httpRouteMatch = [];
        model:HTTPRouteMatch httpRoute = self.retrieveHttpRouteMatch(operation);
        httpRouteMatch.push(httpRoute);
        return httpRouteMatch;
    }

    // Retrieve the GRPC matches for a given operation
    private isolated function retrieveGRPCMatches(APKOperations operation, string endpointType) returns model:GRPCRouteMatch[]|error {
        model:GRPCRouteMatch[] grpcRouteMatch = [];
        model:GRPCRouteMatch grpcRoute = self.retrieveGrpcRouteMatch(operation);
        grpcRouteMatch.push(grpcRoute);
        return grpcRouteMatch;
    }

    // Retrieve the HTTP match for a given operation
    private isolated function retrieveHttpRouteMatch(APKOperations operation) returns model:HTTPRouteMatch {
        return {method: <string>operation.verb, path: {'type: "RegularExpression", value: self.retrievePathPrefix(operation.target ?: "/*", self.apkConf.basePath)}};
    }

    // Retrieve the GRPC match for a given operation
    private isolated function retrieveGrpcRouteMatch(APKOperations operation) returns model:GRPCRouteMatch {
        return {
            method: {
                'type: "Exact",
                'service: <string>operation.target,
                method: <string>operation.verb
            }
        };
    }

    // Retrieve the prepared path prefix
    private isolated function retrievePathPrefix(string operation, string basePath) returns string {
        string[] splitValues = regex:split(operation, "/");
        string generatedPath = "";
        if (operation == "/*") {
            return "(.*)";
        } else if operation == "/" {
            return "/";
        }
        foreach string pathPart in splitValues {
            if pathPart.trim().length() > 0 {
                // Path contains path param
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
        return basePath + generatedPath.trim();
    }

    private isolated function getHostNames(string uniqueId, string endpointType) returns string[] {
        string[] hosts = [];
        string environment = self.apkConf.environment ?: "";
        string orgAndEnv = self.organization.name;
        if environment != "" {
            orgAndEnv = string:concat(orgAndEnv, "-", environment);
        }
        return hosts;
    }

    private isolated function generateFilters(model:Endpoint endpoint, APKOperations operation, string endpointType) returns [model:HTTPRouteFilter[], boolean] {
        model:HTTPRouteFilter[] routeFilters = [];
        boolean hasRedirectPolicy = false;
        APIOperationPolicies? operationPoliciesToUse = ();
        APIOperationPolicies? operationPolicies = self.apkConf.apiPolicies;
        if (operationPolicies is APIOperationPolicies && operationPolicies != {}) {
            if operationPolicies.request is APKRequestOperationPolicy[] || operationPolicies.response is APKResponseOperationPolicy[] {
                operationPoliciesToUse = self.apkConf.apiPolicies;
            }
        } else {
            operationPoliciesToUse = operation.operationPolicies;
        }
        if operationPoliciesToUse is APIOperationPolicies {
            APKRequestOperationPolicy[]? requestPolicies = operationPoliciesToUse.request;
            APKResponseOperationPolicy[]? responsePolicies = operationPoliciesToUse.response;
            if requestPolicies is APKRequestOperationPolicy[] && requestPolicies.length() > 0 {
                model:HTTPRouteFilter[] requestHttpRouteFilters = [];
                [requestHttpRouteFilters, hasRedirectPolicy] = self.extractHttpRouteFilter(endpoint, operation, requestPolicies, true);
                routeFilters.push(...requestHttpRouteFilters);
            }
            if responsePolicies is APKResponseOperationPolicy[] && responsePolicies.length() > 0 {
                model:HTTPRouteFilter[] responseHttpRouteFilters = [];
                [responseHttpRouteFilters, _] = self.extractHttpRouteFilter(endpoint, operation, responsePolicies, false);
                routeFilters.push(...responseHttpRouteFilters);
            }
        }
        if !hasRedirectPolicy {
            string generatedPath = self.generatePrefixMatch(endpoint, operation);
            model:HTTPRouteFilter replacePathFilter = {
                'type: "URLRewrite",
                urlRewrite: {
                    path: {
                        'type: "ReplaceFullPath",
                        replaceFullPath: generatedPath
                    }
                }
            };
            routeFilters.push(replacePathFilter);
        }
        return [routeFilters, hasRedirectPolicy];
    }

    private isolated function extractHttpRouteFilter(model:Endpoint endpoint, APKOperations operation, APKOperationPolicy[] operationPolicies, boolean isRequest) returns [model:HTTPRouteFilter[], boolean] {
        model:HTTPRouteFilter[] httpRouteFilters = [];
        model:HTTPHeader[] addHeaders = [];
        model:HTTPHeader[] setHeaders = [];
        string[] removeHeaders = [];
        boolean hasRedirectPolicy = false;
        foreach APKOperationPolicy policy in operationPolicies {
            if policy is HeaderModifierPolicy {
                HeaderModifierPolicyParameters policyParameters = policy.parameters;
                match policy.policyName {
                    AddHeader => {
                        model:HTTPHeader addHeader = {
                            name: policyParameters.headerName,
                            value: <string>policyParameters.headerValue
                        };
                        addHeaders.push(addHeader);
                    }
                    SetHeader => {
                        model:HTTPHeader setHeader = {
                            name: policyParameters.headerName,
                            value: <string>policyParameters.headerValue
                        };
                        setHeaders.push(setHeader);
                    }
                    RemoveHeader => {
                        removeHeaders.push(policyParameters.headerName);
                    }
                }
            } else if policy is RequestMirrorPolicy {
                RequestMirrorPolicyParameters policyParameters = policy.parameters;
                string[] urls = <string[]>policyParameters.urls;
                foreach string url in urls {
                    model:HTTPRouteFilter mirrorFilter = {'type: "RequestMirror"};
                    if !isRequest {
                        log:printError("Mirror filter cannot be appended as a response policy.");
                    }
                    int|error port = getPort(url);
                    if port is int {
                        model:BackendRef backendRef = self.retrieveGeneratedBackendRefs(endpoint, "")[0];
                        mirrorFilter.requestMirror = {
                            backendRef: {
                                name: backendRef.name,
                                namespace: backendRef.namespace,
                                group: backendRef.group,
                                kind: backendRef.kind,
                                port: backendRef.port
                            }
                        };
                    }
                    httpRouteFilters.push(mirrorFilter);
                }
            } else if policy is RequestRedirectPolicy {
                hasRedirectPolicy = true;
                if !isRequest {
                    log:printError("Redirect filter cannot be appended as a response policy.");
                }
                RequestRedirectPolicyParameters policyParameters = policy.parameters;
                string url = <string>policyParameters.url;
                model:HTTPRouteFilter redirectFilter = {'type: "RequestRedirect"};
                int|error port = getPort(url);
                if port is int {
                    redirectFilter.requestRedirect = {
                        hostname: getHost(url),
                        scheme: getProtocol(url),
                        path: {
                            'type: "ReplaceFullPath",
                            replaceFullPath: getPath(url)
                        }
                    };
                    if policyParameters.statusCode is int {
                        int statusCode = <int>policyParameters.statusCode;
                        redirectFilter.requestRedirect.statusCode = statusCode;
                    }
                }
                httpRouteFilters.push(redirectFilter);
            }
        }
        if isRequest {
            model:HTTPHeaderFilter requestHeaderModifier = {};
            if addHeaders != [] {
                requestHeaderModifier.add = addHeaders;
            }
            if setHeaders != [] {
                requestHeaderModifier.set = setHeaders;
            }
            if removeHeaders != [] {
                requestHeaderModifier.remove = removeHeaders;
            }

            if addHeaders.length() > 0 || setHeaders.length() > 0 || removeHeaders.length() > 0 {
                model:HTTPRouteFilter headerModifierFilter = {
                    'type: "RequestHeaderModifier",
                    requestHeaderModifier: requestHeaderModifier
                };
                httpRouteFilters.push(headerModifierFilter);
            }
        } else {
            model:HTTPHeaderFilter responseHeaderModifier = {};
            if addHeaders != [] {
                responseHeaderModifier.add = addHeaders;
            }
            if setHeaders != [] {
                responseHeaderModifier.set = setHeaders;
            }
            if removeHeaders != [] {
                responseHeaderModifier.remove = removeHeaders;
            }
            if addHeaders.length() > 0 || setHeaders.length() > 0 || removeHeaders.length() > 0 {
                model:HTTPRouteFilter headerModifierFilter = {
                    'type: "ResponseHeaderModifier",
                    responseHeaderModifier: responseHeaderModifier
                };
                httpRouteFilters.push(headerModifierFilter);
            }
        }
        return [httpRouteFilters, hasRedirectPolicy];
    }

    private isolated function retrieveGeneratedBackendRefs(model:Endpoint endpoint, string endpointType) returns model:HTTPBackendRef[] {
        model:HTTPBackendRef httpBackend = {
            kind: "Service",
            name: <string>endpoint.name,
            group: ""
        };
        return [httpBackend];
    }

    private isolated function generatePrefixMatch(model:Endpoint endpoint, APKOperations operation) returns string {
        string target = operation.target ?: "/*";
        string[] splitValues = regex:split(target, "/");
        string generatedPath = "";
        int pathparamCount = 1;
        if (target == "/*") {
            generatedPath = "\\1";
        } else if (target == "/") {
            generatedPath = "/";
        } else {
            foreach int i in 0 ..< splitValues.length() {
                if splitValues[i].trim().length() > 0 {
                    // path contains path param
                    if regex:matches(splitValues[i], "\\{.*\\}") {
                        generatedPath = generatedPath + "/" + regex:replaceAll(splitValues[i].trim(), "\\{.*\\}", "\\" + pathparamCount.toString());
                        pathparamCount += 1;
                    } else {
                        generatedPath = generatedPath + "/" + splitValues[i];
                    }
                }
            }
        }
        if generatedPath.endsWith("/*") {
            int lastSlashIndex = <int>generatedPath.lastIndexOf("/", generatedPath.length());
            generatedPath = generatedPath.substring(0, lastSlashIndex) + "///" + pathparamCount.toString();
        }
        if endpoint.serviceEntry {
            return generatedPath.trim();
        }
        return generatedPath;
    }

    private isolated function generateParentRefs(GatewayConfigurations gatewayConfiguration) returns model:ParentReference[] {
        string gatewayName = gatewayConfiguration.name;
        string listenerName = gatewayConfiguration.listenerName;
        model:ParentReference[] parentRefs = [];
        model:ParentReference parentRef = {group: "gateway.networking.k8s.io", kind: "Gateway", name: gatewayName, sectionName: listenerName};
        parentRefs.push(parentRef);
        return parentRefs;
    }

    private isolated function getLabels() returns map<string> {
        string apiNameHash = crypto:hashSha1(self.apkConf.name.toBytes()).toBase16();
        string apiVersionHash = crypto:hashSha1(self.apkConf.'version.toBytes()).toBase16();
        string organizationHash = crypto:hashSha1(self.organization.name.toBytes()).toBase16();
        map<string> labels = {
            [API_NAME_HASH_LABEL]: apiNameHash,
            [API_VERSION_HASH_LABEL]: apiVersionHash,
            [ORGANIZATION_HASH_LABEL]: organizationHash,
            [MANAGED_BY_HASH_LABEL]: MANAGED_BY_HASH_LABEL_VALUE
        };
        return labels;
    }

    public isolated function getServiceUid(APKOperations? operation, string endpointType) returns string {
        string concatenatedString = uuid:createType1AsString();
        if (operation is APKOperations) {
            return "service-" + concatenatedString + "-resource";
        } else {
            concatenatedString = string:'join("-", self.organization.name, self.apkConf.name, self.'apkConf.'version, endpointType);
            byte[] hashedValue = crypto:hashSha1(concatenatedString.toBytes());
            concatenatedString = hashedValue.toBase16();
            return "service-" + concatenatedString + "-api";
        }
    }

}

