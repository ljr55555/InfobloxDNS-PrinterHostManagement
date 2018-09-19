# InfobloxDNS-PrinterHostManagement
My employer maintains a hardware asset inventory database. Although all printers are entered into the inventory database, 
printer host records were manually created. To eliminate delay and work effort (time creating tickets, time making simple
DNS entries, and time closing tickets), I automated DNS A record creation using the Infoblox API. 

Doing so requires a view (or query) that returns only printer records. To avoid allowing someone to overwrite business-critical
hostnames, we created a printers subdomain -- otherwise someone count enter a printer record named www and overwrite www.company.gTLD.
Creating or modifying www.printers.company.gTLD doesn't have the same impact. 
