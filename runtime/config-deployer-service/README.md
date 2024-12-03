## APK Config Deployer Service

APK Config Deployer Service.

# Functionalities.

1. Generate APK configuration (api.apk-conf) from given OAS definition.
2. Generate K8s artifacts from given definition and APK configuration file.
3. Deploy API into Gateway getting from APK configuration and definition.
4. Undeploy API from Gateway.

### Prerequisites

Before starting development, ensure the following dependencies are ready:

1. **apk_common_lib**  
2. **org.wso2.apk.config-<version>-SNAPSHOT.jar**

To prepare these dependencies:

1. Build **apk_common_lib**:
   ```bash
   cd ./common-bal-libs/apk-common-lib/java
   gradle build
   ```

2. Build **config-deployer-service**:
   ```bash
   cd ./runtime/config-deployer-service/java
   gradle build
   ```

### Resolving Unresolved Modules in VS Code

If `wso2/apk_common_lib` still shows unresolved issues in VS Code:

1. Hover over the unresolved module in the editor.
2. Click on **Pull unresolved modules** from the suggestion popup.