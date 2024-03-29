library(shiny)
library(shinyalert)
library(shinymanager)
library(readODS)
library(stringr)
library(readr)
library(DT)
library(dplyr)
library(lubridate)
library(purrr)
library(pdftools)
library(tesseract)
library(testthat)
library(jpeg)
source("credentials.R", encoding = "utf-8")

# Afin de ne pas exposer de secrets sur github, les identifiants de connexion
# sont stockés dans un fichier séparé, nommé 'credentials.r'. 
# Exemple de contenu :
# credentials <- data.frame(
#     user = c("MyUser"), # mandatory
#     password = c("aPassword"), # mandatory
#     start = c("2021-04-15"), # optinal (all others)
#     expire = c("2023-04-15"),
#     admin = c(FALSE),
#     comment = "Simple and secure authentication mechanism 
#   for single ‘Shiny’ applications.",
#     stringsAsFactors = FALSE
# )

# Si pas déjà le cas, télécharge les données d'entraînement en français 
# pour l'OCR. Ne le fait pas sur Linux (pour Shinyapps)
if (Sys.info()["sysname"] == "Windows" & 
    is.na(match("fra", tesseract_info()$available))) {
  tesseract_download("fra") 
}


# Une fonction qui reconstruit l'URL standard vers les pdf de délibération
guess_url <- function(x, instance,ficname) {
  base_url <- "https://metropole.nantes.fr/files/live/sites/metropolenantesfr/files/assemblees/deliberations"
  docs  = "documents"
  acte <- x[[1]]
  voeu <- x[["Voeu intégré après l'ordre du jour"]]
  delib_date <- ymd(substr(ficname,1,8))
  delib_an <- year(delib_date)
  delib_mois <- format(delib_date, "%m")
  delib_jour <- format(delib_date, "%d")
  delib_mois_jour <- paste(delib_mois, delib_jour, sep = "-")
  if(instance == "CCAS"){  
    index_delib <- str_remove(acte, "^[0-9]{6}")
    index_delib <- str_remove(index_delib, "-.*$")}
  else {
    index_delib <- str_remove(acte, "^[0-9]{4}_")
    index_delib <- str_remove(index_delib, "[A-Z]{2}$")
  }
  index_delib_num <- as.numeric(index_delib)
  first_index <- min(index_delib_num, na.rm = TRUE)
  # Les index des délibérations reprennent à 0 quand le numéro de délib
  # suit le consécutif d'une session précédente
  if (first_index > 5) {
    #Gestion des cas ou une délibération avec un "_b" est présente
    count<-1
    for(i in 1:length(voeu)) {
      #Si on trouve une valeur dans la colonne voeu
      if(!is.na(voeu[i])){
        #On décale le compteur
        count<-count-1
      }
      #Assignation des numéro de délibération
      index_delib_num[i] <- index_delib_num[i] - (first_index - count)
      index_delib[i] <- ifelse(index_delib_num[i] < 10, 
                            paste0("0", index_delib_num[i]),
                            as.character(index_delib_num[i]))
      #Rajout d'un "_b" si présence de voeu
      index_delib[i] <- if(!is.na(voeu[i])){paste0(index_delib[i],"b")}else{index_delib[i]}
      }
    

  }
  # Les URL diffèrent selon les instances.
  if (instance == "conseil-metropolitain") {
    doc_nom <- paste0(index_delib, "_", delib_an, delib_mois, 
                      delib_jour, "_CNM_DEL.pdf")
  } else if (instance == "conseil-municipal") {
    doc_nom = paste0(acte, "_DEL.pdf")
  } else if (instance == "bureau-metropolitain") {
    doc_nom <- paste0(index_delib, "_", delib_an, delib_mois, 
                      delib_jour, "_BNM_DEL.pdf")
  } else if (instance == "CCAS") {
    doc_nom <- paste0(index_delib, "_", delib_an, delib_mois, 
                      delib_jour, "_CCAS_DEL.pdf")
  } else { # on n'a encore rien prévu pour le CCAS
    print("L'instance pour laquelle vous essayez de générer des URL 
                   n'est pas encore prise en compte par cette application")
  }
  
  delib_url_direct <- paste(base_url, instance, delib_an, delib_mois_jour, 
                            docs, doc_nom, sep = "/")
  delib_url_direct <- ifelse(is.na(acte), NA, delib_url_direct)
  return(delib_url_direct)
}

# Une fonction qui vérifie si les url générée tombent bien sur des pdf
gets_pdf <- function(x) {
  httr::HEAD(x)$headers$`content-type` == "application/pdf"
}

# Une fonction qui détermine l'instance dont il s'agit
guess_instance <- function(x) {
  acte <- x[[1]]
  instance <- case_when(
    str_detect(acte, "CM") ~ "conseil-municipal",
    str_detect(acte, "DC") ~ "conseil-metropolitain",
    str_detect(acte, "DB") ~ "bureau-metropolitain",
    str_detect(acte, "DL") ~ "CCAS")
  instance <- tibble(instance) %>%
    count(instance) %>%
    arrange(desc(n)) %>%
    summarise(instance = instance[1])
  instance <- instance[[1]]
  names(instance) <- ifelse(instance == "conseil-municipal", 
                            "Conseil municipal", 
                            ifelse(instance == "conseil-metropolitain",
                                   "Conseil métropolitain",
                                   ifelse(instance == "bureau-metropolitain",
                                          "Bureau métropolitain",
                                          "CA du CCAS")))
  return(instance)
}

clean_logo_VdN <- function(x) {
  x <- str_replace(x, "(^|\n)( \n(\n)?)?v?(V|v|Y)(I|i).*\n(\n)?.*(N|W)( ?)an?.*\n", 
                   "Ville de Nantes")
  x <- str_replace(x, "^VILLE DE(\n\n)?.{1,9}es.?", "Ville de Nantes")
  x <- str_replace(x, "^Nan.{1,9}es.?", "Ville de Nantes")
  x <- str_replace(x, "^nt (D|B)(E|É)(\n\nN?Nant ?es)?", 
                   "Ville de Nantes")
  return(x)
}

clean_logo_NM <- function(x) {
  x <- str_replace(x, "^.?.?( {0,5})?\n? ? ?\n?\n?.? ?Nantes", "Nantes")
  x <- str_replace(x, "Nantes\n\nNES ol", "Nantes\nMétropole")
  return(x)
}

# Une série d'options pour le rendu en français
# Tiré de victorp sur https://stackoverflow.com/questions/54181350
fr <- list(
  sProcessing = "Traitement en cours...", sSearch = "Rechercher&nbsp;:", 
  sLengthMenu = "Afficher _MENU_ &eacute;l&eacute;ments", 
  sInfo = "Affichage de l'&eacute;l&eacute;ment _START_ &agrave; _END_ sur _TOTAL_ &eacute;l&eacute;ments", 
  sInfoEmpty = "Affichage de l'&eacute;l&eacute;ment 0 &agrave; 0 sur 0 &eacute;l&eacute;ment", 
  sInfoFiltered = "(filtr&eacute; de _MAX_ &eacute;l&eacute;ments au total)", 
  sInfoPostFix = "", sLoadingRecords = "Chargement en cours...", 
  sZeroRecords = "Aucun &eacute;l&eacute;ment &agrave; afficher", 
  sEmptyTable = "Aucune donn&eacute;e disponible dans le tableau", 
  oPaginate = list(
    sFirst = "Premier", sPrevious = "Pr&eacute;c&eacute;dent", 
    sNext = "Suivant", sLast = "Dernier"
  ), 
  oAria = list(
    sSortAscending = ": activer pour trier la colonne par ordre croissant", 
    sSortDescending = ": activer pour trier la colonne par ordre d&eacute;croissant"
  )
)

# Interface utilisateur
ui <- fluidPage(
  useShinyalert(),
  #Titre de l'application
  h2("Enrichir un fichier FAST avec les URL des délibérations 
               et leur contenu en texte brut"),
  br(),
  #Barre de menus
  fluidRow(
    column(12,
           column(3, fileInput(inputId = "ods_in",
                               label =NULL,
                               accept = c(".ods", ".csv"),
                               buttonLabel = "Choisir un fichier")),
           column(2, actionButton(inputId = "gen_url",
                                  label = "Générer et tester les URL")),
           column(2, actionButton(inputId = "verif_url",
                                  label = "Tester après modification")),
           column(2, actionButton(inputId = "run_ocr",
                                  label = "Extraire le texte des pdf")),
           column(3, downloadButton("dwn_output", 
                                    label = "Télécharger le fichier enrichi"))),
    hr(),
    column(12, DT::dataTableOutput("fast"))
  )
  
)

# Serveur de l'application
server <- function(input, output) {
  # Authentification pour l'accès à l'application
  res_auth <- secure_server(check_credentials = check_credentials(credentials),
                            timeout = 0)
  output$auth_output <- renderPrint({ reactiveValuesToList(res_auth) })
  # On initie un tableau réactif qui permettra d'éditer les données aux 
  # différentes étapes
  out <- reactiveValues(data = NULL)
  fich_upload <- reactiveValues(name = NULL)
  
  # On inclut un message d'accueil guidant l'utilisateur
  shinyalert(title = "Bienvenue",
             text = "Veuillez choisir un fichier FAST à enrichir
               (format csv ou ods).",
             type = "info", html = TRUE)
  observeEvent(input$ods_in, {
    fich_source <- input$ods_in #récupère le fichier source sélectionné
    req(fich_source) #s'assure que le fichier est valide
    fich_upload$name <- str_remove(fich_source$name[1], "\\..*$")
    extension <- str_extract(fich_source$name[1], "\\..*$") #type de fichier
    validate(need(extension == ".ods" | extension == ".csv", #vérif type
                  "Merci de charger un fichier '.ods' ou '.csv'"))
    if (extension == ".ods") { # si .ods, charge avec la fonction adaptée
      df <- readODS::read_ods(fich_source$datapath[1])
      # On supprime les lignes de titre ou vides en début de certains .ods
      if (str_starts(colnames(df)[1], "Numéro|N°", negate = TRUE)) {
        line_starts <- which.max(str_starts(df[,1], "Numéro|N°"))
        colnames(df) <- df[line_starts,]
        df <- df[(line_starts+1):nrow(df),]
      }
    } else { #si .csv, charge avec la fonction correspondante
      df <- readr::read_csv2(fich_source$datapath[1],
                             locale = locale(encoding = "WINDOWS-1252"))
      if (!("Numéro de l'acte" %in% colnames(df))) {
        df <- readr::read_csv2(fich_source$datapath[1],
                               locale = locale(encoding = "UTF-8"))
      }
    }
    chaine_replace <-c("Â²"="²","Ã¢"="â","Ã»"="û","Ã¨"="è","&quot,"="'","Â "="","Ã "="à","Ã‰"="É","Ã¯"="ï","Ã©"="é","Ãš"="è","ÃŽ"="ô","Ã®"="î","Ãª"="ê","Â "="","Ã "="à")
    df[2]<-str_replace_all(df[[2]],chaine_replace)
    df[5]<-str_replace_all(df[[5]],chaine_replace)
    df[6]<-str_replace_all(df[[6]],chaine_replace)
    names(df) <- trimws(R.utils::capitalize(str_replace_all(names(df),c("œ"="oe","’"="'"))))
    out$data <- df
    out$instance <- guess_instance(out$data)
    out$averif <- TRUE
    shinyalert(title = "Fichier chargé",
               text = paste0("Fichier reconnu (correspondant à un ", 
                             names(out$instance), "). Seules quelques colonnes sont 
                   affichées ici, mais toutes les données sont bien chargées. 
                   Veuillez maintenant générer des URL selon le schéma 
                   habituellement employé pour cette instance."),
               type = "success", html = TRUE)
  })
  
  observeEvent(input$gen_url, {
    out$data <- out$data %>%
      mutate(`URL de la délibération` = guess_url(., instance = out$instance,ficname= fich_upload$name)) %>%
      # même ordre entre affichage et données de base pr éviter erreurs
      relocate(`URL de la délibération`, .after = `Objet de l'acte`)
    withProgress(message = "Test et résolution des URL", value = 0, {
      n <- nrow(out$data)
      for (i in 1:n) {
        acte <- out$data[[1]][i]
        if (is.na(acte) | acte == "") {
          out$data$`URL OK`[i] <- NA
        } else {
          #out$data$`URL OK`[i] = gets_pdf(out$data$`URL de la délibération`[i])
          url_test <- out$data$`URL de la délibération`[i]
          url_ok <- gets_pdf(url_test)
          if (url_ok) {
            out$data$`URL de la délibération`[i] <- url_test
            out$data$`URL OK`[i] = TRUE
          } else {
            # On génère des alternatives
            url_extmaj <- str_replace(url_test, ".pdf", ".PDF")
            url_delibmaj <- str_replace(url_test, "/documents/", 
                                        "/Documents/")
            url_extdelibmaj <- str_replace(url_delibmaj, ".pdf", 
                                           ".PDF")
            url_nozero <- str_replace(url_test, "ocuments/0", 
                                      "ocuments/")
            url_ano <- str_replace(url_test, ".pdf", "_ANO.pdf")
            url_space <- str_replace(url_test, "_", "%20")
            url_cmdel <- str_replace(url_test, "DEL_DEL", "CM_DEL")
            url_doss <- str_replace(url_test, "/documents/", "/D%C3%A9lib%C3%A9rations/")
            url_doss <- str_replace(url_doss, "/assemblees/", "/delib/")
            url_doss <-  str_replace(url_doss, ".pdf", ".PDF")
            url_doss2 <- str_replace(url_test, "/documents/", "/Deliberations/")
            url_doss2 <- str_replace(url_doss2, "/assemblees/", "/delib/")
            url_doss2 <-  str_replace(url_doss2, ".pdf", ".PDF")
            # On teste les alternatives générées
            if (gets_pdf(url_extmaj)) {
              out$data$`URL de la délibération`[i] <- url_extmaj
              out$data$`URL OK`[i] = TRUE
            } else if (gets_pdf(url_extdelibmaj)) {
              out$data$`URL de la délibération`[i] <- url_extdelibmaj
              out$data$`URL OK`[i] = TRUE
            } else if (gets_pdf(url_delibmaj)) {
              out$data$`URL de la délibération`[i] <- url_delibmaj
              out$data$`URL OK`[i] = TRUE
            } else if (gets_pdf(url_space)) {
              out$data$`URL de la délibération`[i] <- url_space
              out$data$`URL OK`[i] = TRUE
            } else if (gets_pdf(url_doss)) {
              out$data$`URL de la délibération`[i] <- url_doss
              out$data$`URL OK`[i] = TRUE
            }else if (gets_pdf(url_nozero)) {
              out$data$`URL de la délibération`[i] <- url_nozero
              out$data$`URL OK`[i] = TRUE
            } else if (gets_pdf(url_ano)) {
              out$data$`URL de la délibération`[i] <- url_ano
              out$data$`URL OK`[i] = TRUE
            } else if (gets_pdf(url_cmdel)) {
              out$data$`URL de la délibération`[i] <- url_cmdel
              out$data$`URL OK`[i] = TRUE
            }else if (gets_pdf(url_doss2)) {
              out$data$`URL de la délibération`[i] <- url_doss2
              out$data$`URL OK`[i] = TRUE
            }else {
              out$data$`URL de la délibération`[i] <- url_test
              out$data$`URL OK`[i] = FALSE
            }
          }
        }
        incProgress(1/n, detail = paste0(i,"/",n))
      }
    })
    # On affiche les URL erronnées
    out$data <- out$data %>%
      mutate(`Test` = ifelse(`URL OK` == TRUE, "URL valide",
                             "URL invalide")) %>%
      # même ordre entre affichage et données de base 
      # pr éviter erreurs
      relocate(`URL OK`, 
               .after = `URL de la délibération`) %>%
      arrange(`URL OK`) # erreurs en premier
    # Vérifie la part d'URL correctes
    url_ok <- mean(out$data$`URL OK`, na.rm  = TRUE)
    if (url_ok == 1) {
      shinyalert(title = "Toutes les URL sont valides",
                 text = "Toutes les URL renvoient bien vers des pdf.
                            Vous pouvez lancer l'extraction du texte.",
                 type = "success")
      out$averif <- FALSE
    } else if (url_ok < 1 & url_ok >= 0.5) {
      shinyalert(title = "Certaines URL doivent être corrigées",
                 text = "La plupart des URL renvoient bien vers des pdf, 
                       mais certaines sont invalides. Veuillez les corriger 
                       manuellement les URL en rouge directement dans le tableau 
                       ci-dessous. Cliquez ensuite sur 'Tester après 
                       modification' pour les valider à nouveau.",
                 type = "warning", html = TRUE)
    } else if (url_ok > 0.3) {
      shinyalert(title = "La plupart des URL doivent être 
                       saisies à la main",
                 text = paste0("Les délibérations ont été mises en ligne avec 
                       des URL trop diverses pour pouvoir les retrouver 
                       automatiquement. Certaines correspondent bien au schéma
                       habituellement utilisé pour les sessions du ",  
                               names(out$instance), ", mais la majorité ne correspond pas. 
                       Veuillez s'il vous plaît les saisir à la main ou faire 
                       en sorte de publier ces délibérations avec des URL 
                       harmonisées."),
                 type = "error", html = TRUE)
    } else {
      shinyalert(title = "Shéma d'URL invalide",
                 text = paste0("Les délibérations pour cette session n'ont 
                       pas été publiées avec des URL correspondant au schéma 
                       habituellement utilisé pour les sessions du ", 
                               names(out$instance), ". Nous vous proposons de tester 
                       automatiquement une série de variantes. Si cela ne 
                       fonctionne pas, il faudra malheureusement saisir les 
                       URL à la main."),
                 type = "error", html = TRUE)
    }
  })
  
  observeEvent(input$verif_url, {
    if (!("Test" %in% colnames(out$data))) {
      shinyalert(title = "Veuillez d'abord générer les URL",
                 text = "Ce bouton sert à vérifier des URL qui auraient 
                       été modifiées manuellement. Mais aucune URL n'a encore 
                       été générée sur ce fichier. Veuiller d'abord cliquer sur
                       'Générer les URL'.",
                 type = "error")
    } else {
      withProgress(message = "Test des URL", value = 0, {
        n <- nrow(out$data)
        for (i in 1:n) {
          if (is.na(out$data[[1]][i]) | out$data[[1]][i] == "") {
            out$data$`URL OK`[i] <- NA
          } else {
            out$data$`URL OK`[i] = gets_pdf(out$data$`URL de la délibération`[i]) 
          }
          incProgress(1/n, detail = paste0(i,"/",n))
        }  
      })
      out$data <- out$data %>%
        mutate(`Test` = ifelse(`URL OK` == TRUE, "URL valide",
                               "URL invalide")) %>%
        arrange(`URL OK`) # erreurs restantes en premier
      # Vérifie la part d'URL correctes
      url_ok <- mean(out$data$`URL OK`, na.rm  = TRUE)
      if (url_ok == 1) {
        shinyalert(title = "Toutes les URL sont valides",
                   text = "Toutes les URL renvoient bien vers des pdf.
                            Vous pouvez lancer l'extraction du texte.",
                   type = "success")
        out$averif <- FALSE
      } else {
        shinyalert(title = "Certaines URL doivent encore être corrigées",
                   text = "Veuillez corriger manuellement les URL en rouge. 
                       Cliquez ensuite sur 'Tester après modification' 
                       pour les valider à nouveau.",
                   type = "warning", html = TRUE)
      }
    }
  })
  # ce qui suit permet d'éditer les reactive values directement dans la table
  proxy = dataTableProxy("fast") 
  observeEvent(input$fast_cell_edit, {
    info = input$fast_cell_edit
    i = info$row
    j = info$col 
    v = info$value
    # -1 pcq les rownames sont comptés dans l'ui et pas dans l'environnement
    # en dessous
    out$data[i, j+1] <<- isolate(DT::coerceValue(v, out$data[i, j]))
    out$averif <- TRUE
  })
  
  observeEvent(input$run_ocr, { # Quand on clique sur 'Extraire le texte...' 
    if (out$averif) { # Message si certaines URL ne sont pas valides
      shinyalert("Attention", 
                 "Certaines URL n'ont pas été validées ou n'ont pas été 
                       vérifiées après correction. Veuillez corriger toutes les 
                       URL apparaîssant sur des lignes en rouge, puis cliquez 
                       sur 'Tester après modification' pour les valider.", 
                 type = "error", html = TRUE)
    } else { # Si pas d'URL invalides, lance l'extraction
      shinyalert("Patience", 
                 "Nous allons maintenant utiliser un réseau de neurones
                       (LSTM) pour extraire le texte brut des fichiers pdf. Le 
                       traitement prend environ 10 secondes par page. Merci 
                       d'avance pour votre patience.", 
                 type = "info", html = TRUE)
      # Paramétrage de l'algo d'extraction (à base de Tesseract)
      n <- nrow(out$data)
      out$data$txt <- ""
      engine <- tesseract(language = "fra",
                          options = list(tessedit_pageseg_mode = "1"))
      withProgress(message = "Extraction du texte", value = 0,
                   detail = paste0("Délibération 1/", n), {
                     for (i in 1:n) {
                       if (is.na(out$data[[1]][i])) { next }
                       pdf <- out$data$`URL de la délibération`[i]
                       pdf_txt <- paste(pdf_text(pdf), collapse = "\n")
                       # Si le doc est déjà OCRisé, on récupère l'OCR déjà dispo
                       # le tampon de la pref est apposée en numérique (~ 150 caractères. On prend 1000 par sécurité)
                       if (nchar(pdf_txt) > 1000) { 
                         out$data$txt[i] <- pdf_txt
                       } else { 
                         np <- pdf_info(pdf)[["pages"]]
                         txtout <- vector(length = np)
                         withProgress(message = "Traitement des pages",
                                      value = 0,
                                      detail = paste0("Page 1/", np), {
                                        for (j in 1:np) {
                                          image <- pdf_render_page(pdf = pdf, page = j, dpi = 300)
                                          t <- ocr(writeJPEG(image), engine = engine)
                                          t <- ifelse(out$instance == "conseil-municipal", 
                                                      clean_logo_VdN(t), t)
                                          t <- ifelse(out$instance == "conseil-metropolitain", 
                                                      clean_logo_NM(t), t)
                                          txtout[j] <- t
                                          incProgress(1/np, detail = paste0("Page ",j+1,"/",np))
                                        }
                                      })
                         out$data$txt[i] = paste(txtout, collapse = "\n")
                       }
                       incProgress(1/n, detail = paste0("Délibération ",i+1,"/",n))
                       out$data <- out$data %>%
                         mutate(txt = str_replace(txt, "(\n|^). Direction", "\nDirection"),
                                txt = str_replace(txt, "(\n|^). Secrétariat", "\nSecrétariat"),
                                txt = str_replace_all(txt, "\nDélibération.{1,5}\n",
                                                      "\nDélibération\n"),
                                txt = str_remove_all(txt, "Accusé de réception en préfecture(\n){1,2}.*\n"),
                                txt = str_remove_all(txt, "Date de télétransmission.*\n"),
                                txt = str_remove_all(txt, "Date de réception.*\n"))
                     }
                   }) 
      shinyalert("Merci pour votre patience", 
                 "Le texte brut a été correctement extrait. Vous pouvez
                       maintenant télécharger le fichier enrichi et l'envoyer à
                       l'équipe open data.", 
                 type = "success", html = TRUE)
    }
  })
  
  
  output$fast <- DT::renderDataTable({
    if (!is.null(out$data)) { # rien n'apparait si aucun fichier sélectionné 
      rendered <- DT::datatable(
        out$data %>%
          select(any_of(c(
            "N° de l'acte",
            "Numéro de l'acte",
            "Objet de l'acte",
            "URL de la délibération",
            "Test"
          ))),
        rownames = FALSE,
        selection = "none",
        editable = TRUE,
        options = list(language = fr))
      
      # Ce bloc colore en rouge les lignes dont les URL sont cassées
      if ("Test" %in% colnames(out$data)) {
        my_color <- "value == 'URL invalide' ? 'red' : ''"  
        class(my_color) <- "JS_EVAL"
        rendered <- rendered %>%
          formatStyle("Test", target = "row",
                      color = my_color)
      }
      
      rendered 
    }
  })
  
  output$dwn_output <- downloadHandler(
    filename = function() {
      paste(fich_upload$name, "_enrichi.csv", sep="")
    },
    content = function(file) {
      out_table <- out$data %>%
        mutate(across(starts_with("Date"),
                      ~ format(dmy(.x), "%d/%m/%Y")))
      out_table <- rename(out_table, "Numéro de l'acte"=1,"Objet de l'acte"=2,"URL de la délibération"=3,"Date de décision"=5,"Code matière"=6,"Niveau 1 de la matière"=7,"Niveau 2 de la matière"=8,"Date de l'AR"=9,"Effectif théorique des votants"=10,"Effectif réel des votants (présents et représentés)"=11,"Pour"=12,"Contre"=13,"Abstention"=14)
      write_excel_csv(out_table, file, na = "")
    }
  )
}

# Run the application 
shinyApp(ui = secure_app(ui, language = "fr"), server = server)
