#Variables
RESOURCE_GROUP="private-aks"
LOCATION="North Europe"
AKS_NAME="private-aks"
VNET_NAME="aks-vnet"
AKS_VNET_CIDR=10.10.0.0/16
AKS_SUBNET_NAME="aks-subnet"
AKS_SUBNET_CIDR=10.10.1.0/24

#Create resource group
az group create -n $RESOURCE_GROUP -l $LOCATION

#Create the virtual network
az network vnet create \
--name $VNET_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--address-prefixes $AKS_VNET_CIDR \
--subnet-name $AKS_SUBNET_NAME \
--subnet-prefixes $AKS_SUBNET_CIDR

#Create a service principal and assign permissions
az ad sp create-for-rbac --skip-assignment > auth.json

VNET_ID=$(az network vnet show --resource-group $RESOURCE_GROUP --name $VNET_NAME --query id -o tsv)
SUBNET_ID=$(az network vnet subnet show --resource-group $RESOURCE_GROUP --vnet-name $VNET_NAME --name $AKS_SUBNET_NAME --query id -o tsv)

APP_ID=$(jq -r .appId auth.json)
SECRET=$(jq -r .password auth.json)

# The service principal needs to have permissions to manage the virtual network
az role assignment create --assignee $APP_ID --scope $VNET_ID --role "Network Contributor"

#Create a private AKS cluster
az aks create \
--resource-group $RESOURCE_GROUP \
--name $AKS_NAME \
--node-count 1 \
--vnet-subnet-id $SUBNET_ID \
--service-principal $APP_ID \
--client-secret $SECRET \
--generate-ssh-keys \
--load-balancer-sku standard \
--enable-private-cluster  

#Get credentials
az aks get-credentials -n $AKS_NAME -g $RESOURCE_GROUP

#This won't work because I am not connected to the vnet
kubectl get nodes

#Let's create a VPN gateway to connect to the cluster
VPN_GATEWAY_NAME="gateway"
VPN_GATEWAY_CIDR=10.10.2.0/24

#Create a subnet in the vnet for the gateway
az network vnet subnet create \
--name GatewaySubnet \
--vnet-name $VNET_NAME \
--resource-group $RESOURCE_GROUP \
--address-prefixes $VPN_GATEWAY_CIDR

#Create a public IP for the VPN Gateway
az network public-ip create \
  --name "${VPN_GATEWAY_NAME}-ip" \
  --resource-group $RESOURCE_GROUP \
  --allocation-method Dynamic
  
# Define CIDR block for the VPN clients
ADDRESS_POOL_FOR_VPN_CLIENTS=10.30.0.0/16

# Azure Active Directory info
#https://login.microsoftonline.com/<YOUR_TENANT_ID>
TENANT_ID=$(jq -r .tenant auth.json)
AZURE_VPN_CLIENT_ID="41b23e61-6c1e-4545-b367-cd054e0ed4b4"
#You have to consent Azure VPN application in your tenant first:
https://login.microsoftonline.com/common/oauth2/authorize?client_id=41b23e61-6c1e-4545-b367-cd054e0ed4b4&response_type=code&redirect_uri=https://portal.azure.com&nonce=1234&prompt=admin_consent

# Create a VPN Gateway
az network vnet-gateway create \
  --name $VPN_GATEWAY_NAME \
  --location $LOCATION \
  --public-ip-address "${VPN_GATEWAY_NAME}-ip" \
  --resource-group $RESOURCE_GROUP \
  --vnet $VNET_NAME \
  --gateway-type Vpn \
  --sku VpnGw2 \
  --vpn-type RouteBased \
  --address-prefixes $ADDRESS_POOL_FOR_VPN_CLIENTS \
  --client-protocol OpenVPN \
  --vpn-auth-type AAD \
  --aad-tenant "https://login.microsoftonline.com/${TENANT_ID}" \
  --aad-audience $AZURE_VPN_CLIENT_ID \
  --aad-issuer "https://sts.windows.net/${TENANT_ID}/"

# Get VPN client configuration
az network vnet-gateway vpn-client generate \
--resource-group $RESOURCE_GROUP \
--name $VPN_GATEWAY_NAME

### Option 1: Use /etc/hosts to resolve private link

#Get AKS private link
PRIVATE_FQDN=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_NAME --query "privateFqdn" -o tsv)

#Get private IP
NODE_RESOURCE_GROUP=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_NAME --query "nodeResourceGroup" -o tsv)
KUBE_API_SERVER_IP=$(az network nic list --resource-group $NODE_RESOURCE_GROUP --query "[?contains(name, 'kube-apiserver')].ipConfigurations[0].privateIpAddress" -o tsv)

echo "$KUBE_API_SERVER_IP $PRIVATE_FQDN" >> /etc/hosts

# Modify /etc/hosts with the name of the private link
sudo code /etc/hosts

### Option 2: Use DNS Forwarder in the vnet (https://www.returngis.net/2021/11/resolver-azure-private-links-desde-una-vpn-con-dns-forwarder/)
docker build -t 0gis0/dns-forwarder . && docker push 0gis0/dns-forwarder

ACI_SUBNET_CIDR=10.10.3.0/24

az container create \
  --name dnsforwarder \
  --resource-group $RESOURCE_GROUP \
  --image 0gis0/dns-forwarder  \
  --vnet $VNET_NAME \
  --vnet-address-prefix $AKS_VNET_CIDR \
  --subnet aci-subnet \
  --subnet-address-prefix $ACI_SUBNET_CIDR

# And add the ACI private IP to the /etc/resolv.conf