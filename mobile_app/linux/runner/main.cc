#include "evilcrow_rf_controller.h"

int main(int argc, char** argv) {
  g_autoptr(EvilcrowRfController) app = evilcrow_rf_controller_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
