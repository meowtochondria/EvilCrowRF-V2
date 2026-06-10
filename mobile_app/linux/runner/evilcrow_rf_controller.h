#ifndef EVILCROW_RF_CONTROLLER_H_
#define EVILCROW_RF_CONTROLLER_H_

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(EvilcrowRfController,
                     evilcrow_rf_controller,
                     ERC,
                     CONTROLLER,
                     GtkApplication)

/**
 * evilcrow_rf_controller_new:
 *
 * Creates a new Flutter-based application.
 *
 * Returns: a new #EvilcrowRfController.
 */
EvilcrowRfController* evilcrow_rf_controller_new();

#endif  // EVILCROW_RF_CONTROLLER_H_
