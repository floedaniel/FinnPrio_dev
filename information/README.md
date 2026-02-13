**FinnPRIO Assessor**

FinnPRIO Assessor produce assessments conducted for Sweden made with the FinnPRIO model (Heikkila et al. 2016) . It is a modified version of the original app FinnPRIO developed in the Risk Assessment Unit of the Finnish Food Authority. (Marinova-Todorova et al. 2022). The current Shiny application and model modification was conducted by the Swedish Risk Assessment Unit, at the Swedish university of Agricultural Sciences. <https://www.slu.se/risk-assessment>

**FinnPRIO model**

FinnPRIO is a model for ranking non-native plant pests based on the risk that they pose to plant health (Heikkila et al. 2016) . It is composed of five sections: likelihood of entry, likelihood of establishment and spread, magnitude of impacts, preventability, and controllability. The score describing the likelihood of invasion is a product of entry and establishment scores. The score describing the manageability of invasion is the minimum of prevantability and controllability scores.

FinnPRIO consists of multiple-choice questions with different answer options yielding a different number of points. For each question, the most likely answer option and the plausible minimum and maximum options are selected based on the available scientific evidence. The selected answer options are used to define a PERT probability distribution and the total section scores are obtained with Monte Carlo simulation. The resulting probability distributions of the section scores describe the uncertainty of the assessment. Summary statistics of the score distributions can be explored in the tab 'Plot pests on a graph'
