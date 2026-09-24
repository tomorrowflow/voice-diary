This guideline serves as a highly simplified, summarized guide to the most important Harvest booking rules.
 
Rules of procedure 
To achieve a better overall planning, both for customer project budgets and our internal investment in Gaia, all employees comply with the following regulations:
•	The Harvest performance records are recorded daily by all employees at the end of working hours.
•	At the end of each working week, the timesheet for that week must be submitted on Fridays so that the team lead can check it on Mondays. This is possible by clicking the button “Submit week for approval” below the tracked time.
Open image-20250506-135510.png
 
•	Please note that the timesheet always applies to the entire week. If it is submitted, it can no longer be withdrawn. If it is approved, it can no longer be processed.
 
 
 
KommunalPlattform
If you’re working on NetzeBW-Project Kommunalplattform 100%, please be aware to follow the Guideline provided by Jannick Maurer. 
You can find it here.
In that case you can stop reading this guide  
 
 
 
Timetracking example
 The Harvest entries are the basis for the customer invoice and are also attached to the invoice as proof of performance in the interests of transparency. All entries must therefore be 100% valid and the comments must be “customer-compatible” and clearly comprehensible. The primary language is German or English.
Open image-20250506-141147.png
•	Granularity 
The day's work is to be recorded in Harvest, divided into logically meaningful blocks. For an 8-hour day, this should be at least 2, max. 8 entries. Exceptions to this are trade fairs/events, all-day workshops and all-day work on a Jira story (in this case, however, several sight words of the work in the notes).
•	Assesment basis "Time" 
The net working time is recorded, i.e. breaks must be deducted. For employees who work with the Harvest timer, make sure that the rounding function (1/4h) is set in Harvest. A position should not exceed 4 hours.
•	Activity documentation „Project“ 
All activities are assigned to a project. These can be internal projects (e.g. Weiterentwicklung GAIA planning)) or external customer projects (e.g. Netze BW KommunalPlattform 2025; EVI Energieversorgung Hildesheim). 
•	Activity documentation „Task“ 
The tasks are standardized so that they can be compared and evaluated. The current list of all valid tasks with descriptions and examples can be found in the last chapter.
•	Activity documentation„Note“ 
Each entry must be supplemented with a short, descriptive “Note”. If there is a clear reference to a Jira task, this should be stated at the beginning of the “note”.
 
 
Further information on enersis internal projects  
The enersis internal projects are briefly described below and underpinned with examples of reporting.
Project 	Description 	Examples 
Weiterentwicklung GAIA buildings 	Development of Features & Deploy- ments/Testing/DevOps for the module buildings 	 
Weiterentwicklung GAIA co2balance 	Development of Features & Deploy- ments/Testing/DevOps for the module co2balance	 
Weiterentwicklung GAIA renewables 	Development of Features & Deploy- ments/Testing/DevOps for the module renewables	 
Weiterentwicklung GAIA planning 	Development of Features & Deploy- ments/Testing/DevOps for the module planning	 
Weiterentwicklung GAIA powergrids	Development of Features & Deploy- ments/Testing/DevOps for the module powergrids	 
Weiterentwicklung GAIA constructions 	Development of Features & Deploy- ments/Testing/DevOps for the module constructions	 
Weiterentwicklung GAIA outages 	Development of Features & Deploy- ments/Testing/DevOps for the module outages	 
Weiterentwicklung GAIA Modulübergreifend 
(new!)	Development of Features und Deploy- ments/Testing/DevOps, which cannot be assigned to a specific module. 	Meetings like Backlog Refinement, Planning, Review & Retro if its not customer related or if you can’t use the task your currently working on. Use the task “03_01_Technische_Entwicklung”
 
e.g. Revision of contact option
Features that affect all modules equally during deployment
GAIA Operations 	Everything that ensures that our current application runs.
Work for the further development and maintenance of the platform services (operations)	Support (starting with problem reports, Freshdesk)
Operation of the infrastructure
Maintenance
Update of technologies
Non-customer-specific SaaS expenses
Revision of architecture
DevOps/Operations topics
Weiterentwicklung shared services 
(former known as GAIA Plattform Services)	Further development of gaia components that have a concrete application reference.
 
Creates concrete values for the application.	IDM
Admin Panel Implementation Dashpad
Concept and implementation of core services
Layerpanel/usermanagement
SSO components
Implementation of Resource Store, Kafka, Istio, Airflow, Keycloak
Weiterentwicklung Systeminfrastruktur 
(former known as GAIA Plattform)	Further development of gaia components that have a concrete infrastructure reference (today almost only Prodigies and partly Pacman) 	Improving system onboarding
automation
monitoring
 
Standardized task structure for customer projects 
Task 	Description 	Example 
01_Projektmanagement 	This is primarily for the project managers	e.g. Erstellung Projektplan, - budget 
03_01_Technische Entwicklung 	This is primarily for the developers and will be right in almost every case.
Technical conception at development level
coding
Necessary planning activities
Scrum meetings	Front-/Back-end development
ETL development Interface development Data model
Scrum meetings (attention: do not show daily separately)
03_04_Design 	This is primarily for the UX designers
UI/UX, design topics, UCD, processing customer feedback	e.g. creation of mockups
03_07_Data_Engineering 	Working in the field of data science/engineering	e.g. Structure of mock data set for initial measure set
03_08_Testing 	Efforts in the area of testing (manual tests, end-to-end tests)	e.g. testing of functions, testing according to publishes
03_09_Releasemanagement 	feature publish in the production environment 	publish efforts Staging → Production 
04_Dokumentation 	Efforts for documentations	e.g. writing a documentation, best practice, … in github or confluence

