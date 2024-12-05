import wso2/apk_common_lib as commons;

public class GatewayKong {
    private APKConf apkConf;
    private string? apiDefinition;
    private commons:Organization organization;

    public isolated function init(APKConf conf, string? apiDefinition, commons:Organization organization) {
        self.apkConf = conf;
        self.apiDefinition = apiDefinition;
        self.organization = organization;
    }

    public isolated function generateK8sArtifacts() returns string|commons:APKError {
        do {
            GatewayModel gatewayModel = new (self.apkConf, self.apiDefinition, self.organization);
            return gatewayModel.prepareArtifact();
        }
        on fail var e {
            if e is commons:APKError {
                return e;
            }
            return e909022("Internal Error occured while generating k8s-artifact", e);
        }
    }

}
