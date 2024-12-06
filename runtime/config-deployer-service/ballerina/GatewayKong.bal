import wso2/apk_common_lib as commons;

public class GatewayKong {
    private final string apiVersion = "configuration.konghq.com/v1";
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
            GatewayConfigurations kongGatewayConfigurations = {
                name: "kong",
                listenerName: "https"
            };
            GatewayModel gatewayModel = new (self.apkConf, self.apiDefinition, self.organization, kongGatewayConfigurations);
            GatewayModelArtifact gatewayModelArtifact = check gatewayModel.prepareArtifact();
            // todo: add kong plugins
            return gatewayModelArtifact.toJsonString();
        }
        on fail var e {
            if e is commons:APKError {
                return e;
            }
            // return e909022("Internal Error occurred while generating k8s-artifact", e);
        }
    }

}
