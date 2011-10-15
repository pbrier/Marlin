#ifndef SCREEN_H
#define SCREEN_H
#include "Configuration.h"
#include "ultralcd.h"


#include <WProgram.h>
#include "fastio.h"

#define LCD_COLS       LCD_WIDTH    
#define LCD_ROWS       LCD_HEIGHT

/*
    LCD pin configuration currently only supports 4bit and no R/W pin
    Set the defines below to match your configuration
*/
#define LCD_RS_PIN     LCD_PINS_RS        // Register Select
#define LCD_E_PIN      LCD_PINS_ENABLE    // Enable pin
    
#define LCD_DB4_PIN    LCD_PINS_D4        // Data pin 4
#define LCD_DB5_PIN    LCD_PINS_D5        // Data pin 5
#define LCD_DB6_PIN    LCD_PINS_D6        // Data pin 6
#define LCD_DB7_PIN    LCD_PINS_D7        // Data pin 7

#include <stdint.h>
class Screen
{
public:
    Screen();
    Screen(char* baseScreen);
  
    void clear();
    void begin(uint8_t x, uint8_t y);
    char* getCursor() const { return pCurrent; }
    void setCursor(char *pCursor) { pCurrent = pCursor; }
    void setCursor(int col, int row);
    void setCursorRow(int row);

    void print(char ch);
    void print(int value);
    void print(char *text);
    void print(char *text, int count);
    void printRow(int row, char *text);

    void printFloat31(float value);
    void printFloat41(float value);
    
    void createChar(uint8_t location, uint8_t charmap[]);

    bool display();

private:
    char buffer[LCD_ROWS * LCD_COLS];
    char* pCurrent;
};

#endif

