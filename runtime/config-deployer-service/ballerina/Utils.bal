isolated function getDomain(string url) returns string {
    string hostPort = "";
    string protocol = "";
    if url.startsWith("https://") {
        hostPort = url.substring(8, url.length());
        protocol = "https";
    } else if url.startsWith("http://") {
        hostPort = url.substring(7, url.length());
        protocol = "http";
    } else {
        return "";
    }
    int? indexOfSlash = hostPort.indexOf("/", 0);
    if indexOfSlash is int {
        return protocol + "://" + hostPort.substring(0, indexOfSlash);
    } else {
        return protocol + "://" + hostPort;
    }
}

isolated function getPath(string url) returns string {
    string hostPort = "";
    if url.startsWith("https://") {
        hostPort = url.substring(8, url.length());
    } else if url.startsWith("http://") {
        hostPort = url.substring(7, url.length());
    } else {
        return "";
    }
    int? indexOfSlash = hostPort.indexOf("/", 0);
    if indexOfSlash is int {
        return hostPort.substring(indexOfSlash, hostPort.length());
    } else {
        return "";
    }
}

// Extract the host name form the endpoint
isolated function getHost(string|K8sService endpoint) returns string {
    string url;
    if endpoint is string {
        url = endpoint;
    } else {
        url = constructURlFromK8sService(endpoint);
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

isolated function getPort(string|K8sService endpoint) returns int|error {
    string url;
    if endpoint is string {
        url = endpoint;
    } else {
        url = constructURlFromK8sService(endpoint);
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

isolated function constructURlFromService(string|K8sService endpoint) returns string {
    if endpoint is string {
        return endpoint;
    } else {
        return constructURlFromK8sService(endpoint);
    }
}

isolated function constructURlFromK8sService(K8sService 'k8sService) returns string {
    return <string>k8sService.protocol + "://" + string:'join(".", <string>k8sService.name, <string>k8sService.namespace, "svc.cluster.local") + ":" + k8sService.port.toString();
}

isolated function getProtocol(string|K8sService endpoint) returns string {
    if endpoint is string {
        return endpoint.startsWith("https://") ? "https" : "http";
    } else {
        return endpoint.protocol ?: "http";
    }
}
